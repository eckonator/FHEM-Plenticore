################################################################################
# $Id: 73_Plenticore.pm 00001 2026-05-01 00:00:00Z markus $
#
# FHEM module for Kostal Plenticore inverter (local REST API)
# Fetches PV system data directly via the inverter's local HTTP/HTTPS REST API
#
# Based on API analysis of MMM-Plenticore (MagicMirror module)
# by Markus Eckert https://github.com/eckonator/
#
# Authentication uses SCRAM-SHA-256 (RFC 5802) as implemented in the
# Kostal SJCL-based login (lib/kostal.js in MMM-Plenticore)
#
# This file is part of fhem.
# Fhem is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
################################################################################

package main;

use strict;
use warnings;
use HttpUtils;
use JSON;
use Encode      qw(encode);
use Time::HiRes qw(gettimeofday);
use POSIX       qw(strftime);
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA  qw(sha256 hmac_sha256);

my $PC_VERSION = "1.0.0";

# Try to load CryptX for AES-256-GCM (required in SCRAM step 3)
my $PC_HAVE_GCM = 0;
eval {
    require Crypt::AuthEnc::GCM;
    Crypt::AuthEnc::GCM->import();
    $PC_HAVE_GCM = 1;
};

################################################################################
# Crypto helpers
################################################################################

# Cryptographically random bytes
sub PC_RandomBytes {
    my ($len) = @_;
    my $bytes = '';
    if (open my $fh, '<:raw', '/dev/urandom') {
        read $fh, $bytes, $len;
        close $fh;
    } else {
        $bytes .= chr(int(rand(256))) for 1..$len;
    }
    return $bytes;
}

# PBKDF2-HMAC-SHA256
# Returns $dklen raw bytes.  hmac_sha256($data, $key) – Digest::SHA order.
sub PC_PBKDF2 {
    my ($password, $salt_bin, $iterations, $dklen) = @_;
    my ($dk, $blk) = ('', 0);
    while (length($dk) < $dklen) {
        $blk++;
        my $u = hmac_sha256($salt_bin . pack('N', $blk), $password);
        my $t = $u;
        for my $i (2 .. $iterations) {
            $u  = hmac_sha256($u, $password);
            $t ^= $u;
        }
        $dk .= $t;
    }
    return substr($dk, 0, $dklen);
}

# AES-256-GCM encrypt.  Returns ($iv_16, $tag_16, $ciphertext) as raw bytes.
# Requires Crypt::AuthEnc::GCM from CryptX.
sub PC_AES256GCM_Encrypt {
    my ($key32, $plaintext) = @_;
    return (undef, undef, undef) unless $PC_HAVE_GCM;
    my $iv  = PC_RandomBytes(16);
    my $gcm = Crypt::AuthEnc::GCM->new('AES', $key32);
    $gcm->iv_add($iv);
    my $ct  = $gcm->encrypt_add(encode('UTF-8', $plaintext));
    my $tag = $gcm->encrypt_done();
    return ($iv, $tag, $ct);
}

################################################################################
# Initialize
################################################################################

sub Plenticore_Initialize {
    my ($hash) = @_;
    $hash->{DefFn}    = \&Plenticore_Define;
    $hash->{UndefFn}  = \&Plenticore_Undef;
    $hash->{DeleteFn} = \&Plenticore_Delete;
    $hash->{SetFn}    = \&Plenticore_Set;
    $hash->{GetFn}    = \&Plenticore_Get;
    $hash->{AttrFn}   = \&Plenticore_Attr;
    $hash->{AttrList} =
        "interval " .
        "port " .
        "https:1,0 " .
        "hasBattery:1,0 " .
        "pvStringCount:1,2,3 " .
        "disable:1,0 " .
        "disabledForIntervals " .
        $readingFnAttributes;
    return;
}

################################################################################
# Define – define <name> Plenticore <ip> [<port>]
################################################################################

sub Plenticore_Define {
    my ($hash, $def) = @_;
    my @a = split /\s+/, $def;
    return "Usage: define <name> Plenticore <ip> [<port>]" if @a < 3;

    my $name = $a[0];
    my $ip   = $a[2];
    my $port = $a[3] // 80;

    $hash->{IP}      = $ip;
    $hash->{PORT}    = $port;
    $hash->{VERSION} = $PC_VERSION;
    $hash->{NOTIFYDEV} = 'global';

    RemoveInternalTimer($hash);

    unless ($PC_HAVE_GCM) {
        Log3($name, 1, "$name: WARNING – Crypt::AuthEnc::GCM not found. "
            . "Install with: apt install libcryptx-perl");
        readingsSingleUpdate($hash, 'state',
            'error: install libcryptx-perl (apt install libcryptx-perl)', 1);
        return;
    }

    my ($err, $pw) = getKeyValue($name . '_password');
    if ($err || !defined $pw || $pw eq '') {
        readingsSingleUpdate($hash, 'state',
            "Passwort setzen: set $name password <Passwort>", 1);
        return;
    }

    readingsSingleUpdate($hash, 'state', 'initializing', 1);
    InternalTimer(gettimeofday() + 2, \&Plenticore_Login, $hash);
    return;
}

################################################################################
# Undef
################################################################################

sub Plenticore_Undef {
    my ($hash) = @_;
    RemoveInternalTimer($hash);
    HttpUtils_Close($hash) if $hash->{httpsession};
    return;
}

################################################################################
# Delete – remove stored password
################################################################################

sub Plenticore_Delete {
    my ($hash, $name) = @_;
    setKeyValue($name . '_password', undef);
    return;
}

################################################################################
# Set
################################################################################

sub Plenticore_Set {
    my ($hash, $name, $cmd, @args) = @_;

    if ($cmd eq 'password') {
        return "Usage: set $name password <Passwort>" unless @args;
        setKeyValue($name . '_password', join(' ', @args));
        Log3($name, 3, "$name: password stored");
        RemoveInternalTimer($hash);
        Plenticore_Login($hash);
        return;
    }

    return Plenticore_UpdateData($hash) if $cmd eq 'update';

    if ($cmd eq 'relogin') {
        $hash->{SESSION_ID} = undef;
        RemoveInternalTimer($hash);
        Plenticore_Login($hash);
        return;
    }

    if ($cmd =~ /^Battery_/) {
        return "Battery not detected (hasBattery not set)"
            unless ($hash->{PC_HAS_BATTERY} // 0);
        my %map = (
            Battery_MinSoc              => 'Battery:MinSoc',
            Battery_Strategy            => 'Battery:Strategy',
            Battery_ExternControl       => 'Battery:ExternControl',
            Battery_ExternControl_Power => 'Battery:ExternControl:DcPowerAbs',
        );
        return "Unknown battery command: $cmd" unless $map{$cmd};
        return "Usage: set $name $cmd <value>"  unless @args;
        Plenticore_PutSetting($hash, 'devices:local', $map{$cmd}, $args[0]);
        return;
    }

    my @opts = qw(password update:noArg relogin:noArg);
    push @opts, qw(Battery_MinSoc Battery_Strategy Battery_ExternControl Battery_ExternControl_Power)
        if ($hash->{PC_HAS_BATTERY} // 0);
    return "Unknown argument $cmd, choose one of " . join(' ', @opts);
}

################################################################################
# Get
################################################################################

sub Plenticore_Get {
    my ($hash, $name, $cmd) = @_;
    return Plenticore_UpdateData($hash)  if $cmd eq 'update';
    return Plenticore_FetchSettings($hash) if $cmd eq 'settings';
    return "Unknown argument $cmd, choose one of update:noArg settings:noArg";
}

################################################################################
# Attr
################################################################################

sub Plenticore_Attr {
    my ($cmd, $name, $attr, $val) = @_;
    my $hash = $defs{$name};
    return unless $hash;

    if ($attr eq 'disable') {
        if ($cmd eq 'set' && $val) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate($hash, 'state', 'disabled', 1);
        } else {
            InternalTimer(gettimeofday() + 1, \&Plenticore_Login, $hash);
        }
    }
    if ($attr eq 'interval' && $cmd eq 'set') {
        RemoveInternalTimer($hash, \&Plenticore_UpdateData);
        InternalTimer(gettimeofday() + ($val // 30),
            \&Plenticore_UpdateData, $hash);
    }
    return;
}

################################################################################
# Internal helpers
################################################################################

sub PC_BaseURL {
    my ($hash) = @_;
    my $name   = $hash->{NAME};
    my $scheme = AttrVal($name, 'https', 0) ? 'https' : 'http';
    my $port   = AttrVal($name, 'port',  $hash->{PORT} // 80);
    return "$scheme://$hash->{IP}:$port/api/v1";
}

sub PC_Headers {
    my ($hash) = @_;
    my $h = "Content-Type: application/json\r\nAccept: application/json";
    $h   .= "\r\nAuthorization: Session $hash->{SESSION_ID}" if $hash->{SESSION_ID};
    return $h;
}

sub PC_ApiCall {
    my ($hash, $method, $endpoint, $body_ref, $callback) = @_;
    my %req = (
        url      => PC_BaseURL($hash) . $endpoint,
        timeout  => 15,
        hash     => $hash,
        method   => uc($method),
        header   => PC_Headers($hash),
        callback => $callback,
    );
    $req{data} = JSON->new->utf8->encode($body_ref) if defined $body_ref;
    HttpUtils_NonblockingGet(\%req);
}

sub PC_IsDisabled {
    my ($hash) = @_;
    return IsDisabled($hash->{NAME});
}

sub PC_ScheduleRetry {
    my ($hash) = @_;
    my $delay = AttrVal($hash->{NAME}, 'interval', 30) * 3;
    RemoveInternalTimer($hash, \&Plenticore_Login);
    InternalTimer(gettimeofday() + $delay, \&Plenticore_Login, $hash);
}

sub PC_ScheduleUpdate {
    my ($hash) = @_;
    my $delay = AttrVal($hash->{NAME}, 'interval', 30);
    RemoveInternalTimer($hash, \&Plenticore_UpdateData);
    InternalTimer(gettimeofday() + $delay, \&Plenticore_UpdateData, $hash);
}

################################################################################
# Login Step 1 – POST /auth/start
################################################################################

sub Plenticore_Login {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return if PC_IsDisabled($hash);
    RemoveInternalTimer($hash, \&Plenticore_Login);

    my ($err, $pw) = getKeyValue($name . '_password');
    if ($err || !defined $pw || $pw eq '') {
        readingsSingleUpdate($hash, 'state',
            "Passwort setzen: set $name password <Passwort>", 1);
        return;
    }

    $hash->{'.scram_pw'}     = $pw;
    $hash->{'.scram_cnonce'} = encode_base64(PC_RandomBytes(18), '');

    Log3($name, 4, "$name: SCRAM login – step 1 (auth/start)");
    readingsSingleUpdate($hash, 'state', 'connecting', 1);

    PC_ApiCall($hash, 'POST', '/auth/start',
        { username => 'user', nonce => $hash->{'.scram_cnonce'} },
        \&Plenticore_LoginStep2Cb
    );
}

################################################################################
# Login Step 2 – compute proof, POST /auth/finish
################################################################################

sub Plenticore_LoginStep2Cb {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    if ($err || $code >= 400) {
        Log3($name, 2, "$name: auth/start error (HTTP $code): " . ($err // $data));
        readingsSingleUpdate($hash, 'state', "error: HTTP $code", 1);
        PC_ScheduleRetry($hash);
        return;
    }

    my $json;
    eval { $json = JSON->new->utf8->decode($data); };
    if ($@ || !$json->{nonce} || !$json->{salt} || !$json->{rounds} || !$json->{transactionId}) {
        Log3($name, 2, "$name: auth/start unexpected response: $data");
        readingsSingleUpdate($hash, 'state', 'login error: step1 response', 1);
        return;
    }

    my $cnonce   = $hash->{'.scram_cnonce'};
    my $snonce   = $json->{nonce};
    my $salt_b64 = $json->{salt};
    my $rounds   = int($json->{rounds});
    my $trans_id = $json->{transactionId};
    my $password = $hash->{'.scram_pw'};

    # SCRAM-SHA-256 key derivation
    my $salt_bin    = decode_base64($salt_b64);
    my $salted_pw   = PC_PBKDF2($password, $salt_bin, $rounds, 32);
    my $client_key  = hmac_sha256('Client Key', $salted_pw);
    my $server_key  = hmac_sha256('Server Key', $salted_pw);
    my $stored_key  = sha256($client_key);

    # authMessage as per SCRAM spec
    my $auth_msg    = "n=user,r=$cnonce,r=$snonce,s=$salt_b64,i=$rounds,c=biws,r=$snonce";
    my $client_sig  = hmac_sha256($auth_msg, $stored_key);
    my $client_proof = $client_key ^ $client_sig;      # XOR byte-for-byte

    # Save for step 3
    $hash->{'.scram_transid'}    = $trans_id;
    $hash->{'.scram_auth_msg'}   = $auth_msg;
    $hash->{'.scram_client_key'} = $client_key;
    $hash->{'.scram_server_key'} = $server_key;
    $hash->{'.scram_stored_key'} = $stored_key;

    Log3($name, 4, "$name: SCRAM login – step 2 (auth/finish)");

    PC_ApiCall($hash, 'POST', '/auth/finish',
        { transactionId => $trans_id, proof => encode_base64($client_proof, '') },
        \&Plenticore_LoginStep3Cb
    );
}

################################################################################
# Login Step 3 – verify server signature, encrypt token, POST /auth/create_session
################################################################################

sub Plenticore_LoginStep3Cb {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    if ($err || $code >= 400) {
        Log3($name, 2, "$name: auth/finish error (HTTP $code): " . ($err // $data));
        readingsSingleUpdate($hash, 'state', "login error: HTTP $code", 1);
        PC_ScheduleRetry($hash);
        return;
    }

    my $json;
    eval { $json = JSON->new->utf8->decode($data); };
    if ($@ || !$json->{token} || !$json->{signature}) {
        Log3($name, 2, "$name: auth/finish unexpected response: $data");
        readingsSingleUpdate($hash, 'state', 'login error: no token', 1);
        return;
    }

    my $auth_msg   = $hash->{'.scram_auth_msg'};
    my $server_key = $hash->{'.scram_server_key'};
    my $client_key = $hash->{'.scram_client_key'};
    my $stored_key = $hash->{'.scram_stored_key'};
    my $trans_id   = $hash->{'.scram_transid'};

    # Verify server signature: HMAC-SHA256(ServerKey, authMsg)
    my $expected_sig = hmac_sha256($auth_msg, $server_key);
    my $received_sig = decode_base64($json->{signature});
    if ($expected_sig ne $received_sig) {
        Log3($name, 1, "$name: SCRAM server signature mismatch – wrong password?");
        readingsSingleUpdate($hash, 'state', 'login error: signature mismatch', 1);
        # Clean up sensitive data
        delete $hash->{$_} for grep /^\.scram_/, keys %$hash;
        return;
    }

    # Derive session key and encrypt token with AES-256-GCM
    # SessionKey = HMAC-SHA256(key=StoredKey, data="Session Key" || authMsg || ClientKey)
    my $session_key = hmac_sha256('Session Key' . $auth_msg . $client_key, $stored_key);
    my ($iv, $tag, $ct) = PC_AES256GCM_Encrypt($session_key, $json->{token});

    unless (defined $iv) {
        Log3($name, 1, "$name: AES-GCM encrypt failed – is libcryptx-perl installed?");
        readingsSingleUpdate($hash, 'state', 'error: AES-GCM unavailable', 1);
        return;
    }

    # Clean up sensitive SCRAM state
    delete $hash->{'.scram_' . $_} for qw(pw cnonce transid auth_msg client_key server_key stored_key);

    Log3($name, 4, "$name: SCRAM login – step 3 (auth/create_session)");

    PC_ApiCall($hash, 'POST', '/auth/create_session',
        {
            transactionId => $trans_id,
            iv            => encode_base64($iv,  ''),
            tag           => encode_base64($tag, ''),
            payload       => encode_base64($ct,  ''),
        },
        \&Plenticore_LoginStep4Cb
    );
}

################################################################################
# Login Step 4 – save sessionId, detect modules
################################################################################

sub Plenticore_LoginStep4Cb {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    if ($err || $code >= 400) {
        Log3($name, 2, "$name: auth/create_session error (HTTP $code): " . ($err // $data));
        readingsSingleUpdate($hash, 'state', "login error: HTTP $code", 1);
        PC_ScheduleRetry($hash);
        return;
    }

    my $json;
    eval { $json = JSON->new->utf8->decode($data); };
    if ($@ || !$json->{sessionId}) {
        Log3($name, 2, "$name: auth/create_session: no sessionId – $data");
        readingsSingleUpdate($hash, 'state', 'login error: no sessionId', 1);
        return;
    }

    $hash->{SESSION_ID}   = $json->{sessionId};
    $hash->{API_LAST_MSG} = 200;
    Log3($name, 3, "$name: login successful");

    Plenticore_GetModules($hash);
}

################################################################################
# GetModules – auto-detect battery and PV string count
################################################################################

sub Plenticore_GetModules {
    my ($hash) = @_;
    Log3($hash->{NAME}, 4, "$hash->{NAME}: fetching module list");
    PC_ApiCall($hash, 'GET', '/modules', undef, \&Plenticore_GetModulesCb);
}

sub Plenticore_GetModulesCb {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    if ($code == 401) {
        Log3($name, 3, "$name: session expired in GetModules, re-login");
        $hash->{SESSION_ID} = undef;
        Plenticore_Login($hash);
        return;
    }
    if ($err || $code >= 400) {
        Log3($name, 2, "$name: GetModules error (HTTP $code): " . ($err // $data));
        PC_ScheduleRetry($hash);
        return;
    }

    my $json;
    eval { $json = JSON->new->utf8->decode($data); };
    if ($@ || ref($json) ne 'ARRAY') {
        Log3($name, 2, "$name: GetModules JSON error: $@");
        PC_ScheduleRetry($hash);
        return;
    }

    my ($pv_cnt, $has_bat) = (0, 0);
    for my $mod (@$json) {
        my $id = $mod->{id} // '';
        $pv_cnt++ if $id =~ /^devices:local:pv\d+$/;
        $has_bat = 1 if $id eq 'devices:local:battery';
    }
    $pv_cnt = 1 if $pv_cnt < 1;

    # Attribute overrides auto-detection
    my $attr_bat = AttrVal($name, 'hasBattery',    undef);
    my $attr_pv  = AttrVal($name, 'pvStringCount', undef);
    $has_bat = $attr_bat if defined $attr_bat;
    $pv_cnt  = $attr_pv  if defined $attr_pv;

    $hash->{PC_HAS_BATTERY}     = $has_bat;
    $hash->{PC_PV_STRING_COUNT} = $pv_cnt;

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'hasBattery',    $has_bat);
    readingsBulkUpdate($hash, 'pvStringCount', $pv_cnt);
    readingsEndUpdate($hash, 1);

    Log3($name, 3, "$name: modules detected – battery=$has_bat pvStrings=$pv_cnt");
    Plenticore_UpdateData($hash);
}

################################################################################
# UpdateData – POST /processdata
################################################################################

sub Plenticore_UpdateData {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    return if PC_IsDisabled($hash);
    RemoveInternalTimer($hash, \&Plenticore_UpdateData);

    unless ($hash->{SESSION_ID}) {
        Plenticore_Login($hash);
        return;
    }

    my $has_bat = $hash->{PC_HAS_BATTERY}     // 0;
    my $pv_cnt  = $hash->{PC_PV_STRING_COUNT} // 1;

    my @payload = (
        {
            moduleid       => 'devices:local',
            processdataids => [qw(Home_P Dc_P HomeBat_P HomeGrid_P HomePv_P LimitEvuAbs EM_State)],
        },
        {
            moduleid       => 'devices:local:ac',
            processdataids => [qw(L1_P L2_P L3_P L1_U L2_U L3_U L1_I L2_I L3_I P Frequency CosPhi)],
        },
        {
            moduleid       => 'devices:local:pv1',
            processdataids => [qw(P U I)],
        },
        {
            moduleid       => 'scb:statistic:EnergyFlow',
            processdataids => [
                qw(Statistic:Yield:Day    Statistic:Yield:Month
                   Statistic:Yield:Year   Statistic:Yield:Total),
                qw(Statistic:Autarky:Day  Statistic:Autarky:Month
                   Statistic:Autarky:Year Statistic:Autarky:Total),
                qw(Statistic:OwnConsumptionRate:Day   Statistic:OwnConsumptionRate:Month
                   Statistic:OwnConsumptionRate:Year  Statistic:OwnConsumptionRate:Total),
                qw(Statistic:EnergyHome:Day    Statistic:EnergyHome:Month
                   Statistic:EnergyHome:Year   Statistic:EnergyHome:Total),
                qw(Statistic:EnergyHomeBat:Day  Statistic:EnergyHomeBat:Month
                   Statistic:EnergyHomeBat:Year Statistic:EnergyHomeBat:Total),
                qw(Statistic:EnergyHomeGrid:Day  Statistic:EnergyHomeGrid:Month
                   Statistic:EnergyHomeGrid:Year Statistic:EnergyHomeGrid:Total),
                qw(Statistic:EnergyHomePv:Day  Statistic:EnergyHomePv:Month
                   Statistic:EnergyHomePv:Year Statistic:EnergyHomePv:Total),
                qw(Statistic:CO2Saving:Day    Statistic:CO2Saving:Month
                   Statistic:CO2Saving:Year   Statistic:CO2Saving:Total),
            ],
        },
    );

    push @payload, { moduleid => 'devices:local:pv2', processdataids => [qw(P U I)] }
        if $pv_cnt >= 2;
    push @payload, { moduleid => 'devices:local:pv3', processdataids => [qw(P U I)] }
        if $pv_cnt >= 3;
    push @payload, { moduleid => 'devices:local:battery', processdataids => [qw(SoC P U I Cycles)] }
        if $has_bat;

    $hash->{SOURCE} = PC_BaseURL($hash) . '/processdata';
    Log3($name, 5, "$name: fetching processdata");

    PC_ApiCall($hash, 'POST', '/processdata', \@payload, \&Plenticore_ProcessdataCb);
}

################################################################################
# ProcessdataCb – parse response and write readings
################################################################################

sub Plenticore_ProcessdataCb {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $code = $param->{code} // 0;

    $hash->{API_LAST_MSG} = $code;

    if ($code == 401) {
        Log3($name, 3, "$name: session expired, re-login");
        $hash->{SESSION_ID} = undef;
        Plenticore_Login($hash);
        return;
    }

    if ($err || $code >= 400) {
        Log3($name, 2, "$name: processdata error (HTTP $code): " . ($err // ''));
        readingsSingleUpdate($hash, 'state', "error: HTTP $code", 1);
        PC_ScheduleUpdate($hash);
        return;
    }

    my $json;
    eval { $json = JSON->new->utf8->decode($data); };
    if ($@ || ref($json) ne 'ARRAY') {
        Log3($name, 2, "$name: processdata JSON error: $@");
        readingsSingleUpdate($hash, 'state', 'json error', 1);
        PC_ScheduleUpdate($hash);
        return;
    }

    # Flat lookup: "moduleid:id" => value
    my %v;
    for my $mod (@$json) {
        my $mid = $mod->{moduleid} // '';
        for my $e (@{ $mod->{processdata} // [] }) {
            $v{"$mid:" . ($e->{id} // '')} = $e->{value} // 0;
        }
    }

    # Derived power values
    my $inv_p  = ($v{'devices:local:ac:L1_P'}  // 0)
               + ($v{'devices:local:ac:L2_P'}  // 0)
               + ($v{'devices:local:ac:L3_P'}  // 0);
    my $home_p = $v{'devices:local:Home_P'} // 0;
    my $grid_p = $inv_p - $home_p;                  # pos=Einspeisung, neg=Bezug
    my $pv_p   = 0;
    for my $n (1 .. ($hash->{PC_PV_STRING_COUNT} // 1)) {
        $pv_p += $v{"devices:local:pv${n}:P"} // 0;
    }

    readingsBeginUpdate($hash);

    # ── Main readings (compatible with old JsonMod names) ──────────────────────
    readingsBulkUpdate($hash, 'PvGenerator',     sprintf('%.0f', $pv_p));
    readingsBulkUpdate($hash, 'Inverter',        sprintf('%.0f', $inv_p));
    readingsBulkUpdate($hash, 'HomeConsumption', sprintf('%.0f', $home_p));
    readingsBulkUpdate($hash, 'Grid',            sprintf('%.0f', $grid_p));

    # ── Battery ────────────────────────────────────────────────────────────────
    if ($hash->{PC_HAS_BATTERY}) {
        readingsBulkUpdate($hash, 'Battery',        sprintf('%.0f',  $v{'devices:local:battery:P'}      // 0));
        readingsBulkUpdate($hash, 'Battery_SoC',    sprintf('%.0f',  $v{'devices:local:battery:SoC'}    // 0));
        readingsBulkUpdate($hash, 'Battery_U',      sprintf('%.2f',  $v{'devices:local:battery:U'}      // 0));
        readingsBulkUpdate($hash, 'Battery_I',      sprintf('%.2f',  $v{'devices:local:battery:I'}      // 0));
        readingsBulkUpdate($hash, 'Battery_Cycles', sprintf('%.0f',  $v{'devices:local:battery:Cycles'} // 0));
    }

    # ── PV strings ────────────────────────────────────────────────────────────
    for my $n (1 .. ($hash->{PC_PV_STRING_COUNT} // 1)) {
        readingsBulkUpdate($hash, "pv${n}_P", sprintf('%.1f', $v{"devices:local:pv${n}:P"} // 0));
        readingsBulkUpdate($hash, "pv${n}_U", sprintf('%.1f', $v{"devices:local:pv${n}:U"} // 0));
        readingsBulkUpdate($hash, "pv${n}_I", sprintf('%.2f', $v{"devices:local:pv${n}:I"} // 0));
    }

    # ── AC phases ──────────────────────────────────────────────────────────────
    for my $ph (1..3) {
        readingsBulkUpdate($hash, "ac_L${ph}_P", sprintf('%.1f', $v{"devices:local:ac:L${ph}_P"} // 0));
        readingsBulkUpdate($hash, "ac_L${ph}_U", sprintf('%.1f', $v{"devices:local:ac:L${ph}_U"} // 0));
        readingsBulkUpdate($hash, "ac_L${ph}_I", sprintf('%.2f', $v{"devices:local:ac:L${ph}_I"} // 0));
    }
    readingsBulkUpdate($hash, 'ac_Frequency', sprintf('%.2f', $v{'devices:local:ac:Frequency'} // 0));
    readingsBulkUpdate($hash, 'ac_CosPhi',    sprintf('%.3f', $v{'devices:local:ac:CosPhi'}    // 0));
    readingsBulkUpdate($hash, 'Dc_P',         sprintf('%.0f', $v{'devices:local:Dc_P'}         // 0));
    readingsBulkUpdate($hash, 'LimitEvuAbs',  sprintf('%.0f', $v{'devices:local:LimitEvuAbs'}  // 0));

    # ── Statistics (Wh→kWh for energy values, % and kg as-is) ────────────────
    my %stat_map = (
        'Statistic:Yield:Day'              => ['Statistic_Yield_Day',              'kwh'],
        'Statistic:Yield:Month'            => ['Statistic_Yield_Month',            'kwh'],
        'Statistic:Yield:Year'             => ['Statistic_Yield_Year',             'kwh'],
        'Statistic:Yield:Total'            => ['Statistic_Yield_Total',            'kwh'],
        'Statistic:Autarky:Day'            => ['Statistic_Autarky_Day',            'pct'],
        'Statistic:Autarky:Month'          => ['Statistic_Autarky_Month',          'pct'],
        'Statistic:Autarky:Year'           => ['Statistic_Autarky_Year',           'pct'],
        'Statistic:Autarky:Total'          => ['Statistic_Autarky_Total',          'pct'],
        'Statistic:OwnConsumptionRate:Day' => ['Statistic_OwnConsumptionRate_Day', 'pct'],
        'Statistic:OwnConsumptionRate:Month'=> ['Statistic_OwnConsumptionRate_Month','pct'],
        'Statistic:OwnConsumptionRate:Year'=> ['Statistic_OwnConsumptionRate_Year','pct'],
        'Statistic:OwnConsumptionRate:Total'=> ['Statistic_OwnConsumptionRate_Total','pct'],
        'Statistic:EnergyHome:Day'         => ['Statistic_EnergyHome_Day',         'kwh'],
        'Statistic:EnergyHome:Month'       => ['Statistic_EnergyHome_Month',        'kwh'],
        'Statistic:EnergyHome:Year'        => ['Statistic_EnergyHome_Year',         'kwh'],
        'Statistic:EnergyHome:Total'       => ['Statistic_EnergyHome_Total',        'kwh'],
        'Statistic:EnergyHomeBat:Day'      => ['Statistic_EnergyHomeBat_Day',       'kwh'],
        'Statistic:EnergyHomeBat:Month'    => ['Statistic_EnergyHomeBat_Month',     'kwh'],
        'Statistic:EnergyHomeBat:Year'     => ['Statistic_EnergyHomeBat_Year',      'kwh'],
        'Statistic:EnergyHomeBat:Total'    => ['Statistic_EnergyHomeBat_Total',     'kwh'],
        'Statistic:EnergyHomeGrid:Day'     => ['Statistic_EnergyHomeGrid_Day',      'kwh'],
        'Statistic:EnergyHomeGrid:Month'   => ['Statistic_EnergyHomeGrid_Month',    'kwh'],
        'Statistic:EnergyHomeGrid:Year'    => ['Statistic_EnergyHomeGrid_Year',     'kwh'],
        'Statistic:EnergyHomeGrid:Total'   => ['Statistic_EnergyHomeGrid_Total',    'kwh'],
        'Statistic:EnergyHomePv:Day'       => ['Statistic_EnergyHomePv_Day',        'kwh'],
        'Statistic:EnergyHomePv:Month'     => ['Statistic_EnergyHomePv_Month',      'kwh'],
        'Statistic:EnergyHomePv:Year'      => ['Statistic_EnergyHomePv_Year',       'kwh'],
        'Statistic:EnergyHomePv:Total'     => ['Statistic_EnergyHomePv_Total',      'kwh'],
        'Statistic:CO2Saving:Day'          => ['Statistic_CO2Saving_Day',           'kg'],
        'Statistic:CO2Saving:Month'        => ['Statistic_CO2Saving_Month',         'kg'],
        'Statistic:CO2Saving:Year'         => ['Statistic_CO2Saving_Year',          'kg'],
        'Statistic:CO2Saving:Total'        => ['Statistic_CO2Saving_Total',         'kg'],
    );

    for my $api_id (keys %stat_map) {
        my ($reading, $unit) = @{ $stat_map{$api_id} };
        my $raw = $v{"scb:statistic:EnergyFlow:$api_id"} // 0;
        my $val = $unit eq 'kwh' ? sprintf('%.2f', $raw / 1000) : sprintf('%.2f', $raw);
        readingsBulkUpdate($hash, $reading, $val);
    }

    my $ts = strftime('%Y-%m-%d %H:%M:%S', gmtime());
    readingsBulkUpdate($hash, 'lastUpdate', $ts);
    readingsEndUpdate($hash, 1);

    # ── Internals ─────────────────────────────────────────────────────────────
    my $interval = AttrVal($name, 'interval', 30);
    $hash->{API_LAST_RES} = int(gettimeofday());
    $hash->{NEXT}         = FmtDateTime(gettimeofday() + $interval);
    $hash->{SOURCE}       = PC_BaseURL($hash) . "/processdata (HTTP 200)";

    my $state = sprintf('PV: %d W | Haus: %d W | Netz: %d W',
        $pv_p, $home_p, $grid_p);
    $state .= sprintf(' | Batterie: %d W | SoC: %d %%',
        $v{'devices:local:battery:P'}  // 0,
        $v{'devices:local:battery:SoC'} // 0)
        if $hash->{PC_HAS_BATTERY};

    readingsSingleUpdate($hash, 'state', $state, 1);

    Log3($name, 5, "$name: readings updated – $state");
    PC_ScheduleUpdate($hash);
}

################################################################################
# PutSetting – PUT /settings (battery control parameters)
################################################################################

sub Plenticore_PutSetting {
    my ($hash, $moduleid, $setting_id, $value) = @_;
    my $name = $hash->{NAME};

    my %req = (
        url      => PC_BaseURL($hash) . '/settings',
        timeout  => 10,
        hash     => $hash,
        method   => 'PUT',
        header   => PC_Headers($hash),
        data     => JSON->new->utf8->encode(
            [{ moduleid => $moduleid, settings => [{ id => $setting_id, value => "$value" }] }]
        ),
        callback => sub {
            my ($p, $e, $d) = @_;
            my $c = $p->{code} // 0;
            if ($e || $c >= 400) {
                Log3($name, 2, "$name: PUT $setting_id failed (HTTP $c): " . ($e // ''));
            } else {
                Log3($name, 3, "$name: PUT $setting_id = $value OK");
                readingsSingleUpdate($hash, 'setting_' . ($setting_id =~ s/[:\s]/_/gr), $value, 1);
            }
        },
    );
    HttpUtils_NonblockingGet(\%req);
}

################################################################################
# FetchSettings – POST /settings (read battery and inverter config)
################################################################################

sub Plenticore_FetchSettings {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    my @payload = (
        {
            moduleid   => 'devices:local',
            settingids => [qw(
                Battery:MinSoc
                Battery:Strategy
                Battery:MinHomeComsumption
                Battery:SmartBatteryControl:Enable
                Battery:DynamicSoc:Enable
                Battery:ExternControl
                Battery:ExternControl:DcPowerAbs
                Battery:ExternControl:MaxChargePowerAbs
                Inverter:MaxApparentPower
                EnergySensor:InstalledSensor
            )],
        },
    );

    PC_ApiCall($hash, 'POST', '/settings', \@payload, sub {
        my ($p, $e, $d) = @_;
        my $code = $p->{code} // 0;
        if ($e || $code >= 400) {
            Log3($name, 2, "$name: FetchSettings error (HTTP $code): " . ($e // ''));
            return;
        }
        my $json;
        eval { $json = JSON->new->utf8->decode($d); };
        return if $@ || ref($json) ne 'ARRAY';

        readingsBeginUpdate($hash);
        for my $mod (@$json) {
            for my $s (@{ $mod->{settings} // [] }) {
                my $rname = 'setting_' . ($s->{id} =~ s/[:\s]/_/gr);
                readingsBulkUpdate($hash, $rname, $s->{value} // '');
            }
        }
        readingsEndUpdate($hash, 1);
        Log3($name, 3, "$name: settings fetched");
    });
}

1;

=pod
=item device
=item summary FHEM module for Kostal Plenticore inverter (local REST API)
=item summary_DE FHEM-Modul für den Kostal Plenticore Wechselrichter (lokale REST-API)

=begin html

<a name="Plenticore"></a>
<h3>Plenticore</h3>

<p>Fetches PV system data from a <b>Kostal Plenticore</b> inverter directly
via its local REST API. No cloud account or external proxy required.</p>

<p>Authentication uses SCRAM-SHA-256 (the same mechanism as the browser
web interface). The factory password is <code>pvmaster</code>.</p>

<p><b>Requirements:</b> Perl modules <code>Digest::SHA</code>,
<code>MIME::Base64</code> (both standard) and
<code>Crypt::AuthEnc::GCM</code> from CryptX:<br>
<code>apt install libcryptx-perl</code></p>

<a name="Plenticoredefine"></a>
<b>Define</b>
<ul>
  <code>define &lt;name&gt; Plenticore &lt;ip&gt; [&lt;port&gt;]</code><br><br>
  <table>
    <tr><td><code>ip</code></td><td>IP address or hostname of the inverter</td></tr>
    <tr><td><code>port</code></td><td>HTTP port (default: 80)</td></tr>
  </table>
</ul>

<a name="Plenticoreset"></a>
<b>Set</b>
<ul>
  <li><code>password &lt;pw&gt;</code> &ndash; store password encrypted and trigger login</li>
  <li><code>update</code> &ndash; immediate data refresh</li>
  <li><code>relogin</code> &ndash; reset session and re-authenticate</li>
  <li><code>Battery_MinSoc &lt;0-100&gt;</code> &ndash; minimum state of charge (%)</li>
  <li><code>Battery_Strategy &lt;0-2&gt;</code> &ndash; battery strategy (0=Auto, 1=MaxSelfConsumption, 2=External)</li>
  <li><code>Battery_ExternControl &lt;0-2&gt;</code> &ndash; external control mode</li>
  <li><code>Battery_ExternControl_Power &lt;W&gt;</code> &ndash; external power setpoint (W)</li>
</ul>

<a name="Plenticoreget"></a>
<b>Get</b>
<ul>
  <li><code>update</code> &ndash; immediate data refresh</li>
  <li><code>settings</code> &ndash; fetch inverter settings into readings</li>
</ul>

<a name="Plenticoreattr"></a>
<b>Attributes</b>
<ul>
  <li><code>interval</code> &ndash; poll interval in seconds (default: 30)</li>
  <li><code>port</code> &ndash; HTTP port override (default: 80)</li>
  <li><code>https</code> &ndash; use HTTPS (default: 0)</li>
  <li><code>hasBattery</code> &ndash; override battery auto-detection (1/0)</li>
  <li><code>pvStringCount</code> &ndash; override PV string count (1/2/3)</li>
  <li><code>disable</code> &ndash; disable all polling (1/0)</li>
  <li><code>disabledForIntervals</code> &ndash; pause polling in time ranges, e.g. <code>00:00-06:00</code></li>
</ul>

<a name="Plenticorereadings"></a>
<b>Readings</b>
<ul>
  <li><code>PvGenerator</code> &ndash; total PV power (W)</li>
  <li><code>Inverter</code> &ndash; inverter AC output (W)</li>
  <li><code>HomeConsumption</code> &ndash; household consumption (W)</li>
  <li><code>Grid</code> &ndash; grid exchange (W, positive=feed-in, negative=purchase)</li>
  <li><code>Battery</code> &ndash; battery power (W, positive=discharge, negative=charge)</li>
  <li><code>Battery_SoC</code> &ndash; state of charge (%)</li>
  <li><code>Battery_U / Battery_I / Battery_Cycles</code> &ndash; battery details</li>
  <li><code>pv1_P / pv1_U / pv1_I</code> &ndash; PV string 1 values (and pv2_, pv3_)</li>
  <li><code>ac_L1_P / ac_L1_U / ac_L1_I</code> &ndash; AC phase values (L1-L3)</li>
  <li><code>ac_Frequency / ac_CosPhi</code> &ndash; grid frequency and power factor</li>
  <li><code>Statistic_Yield_Day / _Month / _Year / _Total</code> &ndash; PV yield (kWh)</li>
  <li><code>Statistic_Autarky_Day ...</code> &ndash; self-sufficiency rate (%)</li>
  <li><code>Statistic_OwnConsumptionRate_Day ...</code> &ndash; self-consumption rate (%)</li>
  <li><code>Statistic_CO2Saving_Day ...</code> &ndash; CO&#x2082; savings (kg)</li>
  <li><code>Statistic_EnergyHome_Day ...</code> &ndash; household energy (kWh)</li>
  <li><code>lastUpdate</code> &ndash; timestamp of last successful fetch (UTC)</li>
  <li><code>hasBattery / pvStringCount</code> &ndash; auto-detected hardware config</li>
</ul>

=end html

=cut
