# FTN::Crypt - Encryption of the FTN messages
#
# Copyright (C) 2019 by Petr Antonov
#
# This library is free software; you can redistribute it and/or modify it
# under the same terms as Perl 5.10.0. For more details, see the full text
# of the licenses at https://opensource.org/licenses/Artistic-1.0, and
# http://www.gnu.org/licenses/gpl-2.0.html.
#
# This package is provided "as is" and without any express or implied
# warranties, including, without limitation, the implied warranties of
# merchantability and fitness for a particular purpose.
#

package FTN::Crypt;

use strict;
use warnings;
use 5.010;

our $VERSION = '0.2.0';

use Carp;

use FTN::Crypt::Constants;
use FTN::Crypt::Msg;
use FTN::Crypt::Nodelist;

use GnuPG::Handles;
use GnuPG::Interface;

use IO::Handle;

use PGP::Finger;

use Try::Tiny;

#----------------------------------------------------------------------#
my $DEFAULT_KEYSERVER_URL = 'https://zimmermann.mayfirst.org/pks/lookup';

my $GPG2_BVER = '2.1.0';

#----------------------------------------------------------------------#
sub new {
    my ($class, %opts) = @_;

    croak "No options specified" unless %opts;

    my $self = {
        keyserver_url => $opts{Keyserver} ? $opts{Keyserver} : $DEFAULT_KEYSERVER_URL,
        gnupg         => GnuPG::Interface->new(),
    };

    $self->{nodelist} = FTN::Crypt::Nodelist->new(
        Nodelist => $opts{Nodelist},
    );
    unless ($self->{nodelist}) {
        croak(FTN::Crypt::Nodelist->error);
    }

    $self->{gnupg}->options->hash_init(
        armor            => 1,
        meta_interactive => 0,
    );

    $self->{gnupg}->options->push_extra_args('--keyring', $opts{Pubring}) if $opts{Pubring};
    $self->{gnupg}->options->push_extra_args('--secret-keyring', $opts{Secring}) if $opts{Secring};
    $self->{gnupg}->options->push_extra_args('--always-trust');

    $self = bless $self, $class;
    return $self;
}

#----------------------------------------------------------------------#
sub encrypt_message {
    my $self = shift;
    my (%opts) = @_;

    my $msg = FTN::Crypt::Msg->new(
        Address => $opts{Address},
        Message => $opts{Message},
    );

    my $res = {
        ok => 0,
        msg => '',
    };

    my ($addr, $method) = $self->{nodelist}->get_email_addr($msg->get_address);
    unless ($addr) {
        $res->{msg} = 'Encryption-capable address not found: ' . $self->{nodelist}->error;
        return $res;
    }

    my $gnupg_ver = $self->{gnupg}->version;
    if ($method eq 'PGP2') {
        if (version->parse($gnupg_ver) < version->parse($GPG2_BVER)) {
            $self->{gnupg}->options->meta_pgp_2_compatible(1);
        } else {
            $res->{msg} = "GnuPG is too new (ver. $gnupg_ver), can't ensure required encryption method ($method)";
            return $res;
        }
    } elsif ($method eq 'PGP5') {
        $self->{gnupg}->options->meta_pgp_5_compatible(1);
    }

    unless ($self->_lookup_key($addr) || $self->_import_key($addr)) {
        $res->{msg} = "PGP key for $addr not found";
        return $res;
    }
    
    my $key_id = $self->_select_key($addr);
    $self->{gnupg}->options->push_recipients($key_id);

    my ($in_fh, $out_fh, $err_fh) = (IO::Handle->new(), IO::Handle->new(),
        IO::Handle->new());

    my $handles = GnuPG::Handles->new(
        stdin  => $in_fh,
        stdout => $out_fh,
        stderr => $err_fh,
    );

    my $pid = $self->{gnupg}->encrypt(handles => $handles);

    print $in_fh $msg->get_text;
    close $in_fh;

    my $msg_enc = join '', <$out_fh>;
    close $out_fh;

    close $err_fh;
    
    waitpid $pid, 0;

    if ($msg_enc) {
        $res->{ok} = 1;
        $msg->set_text($msg_enc);
        $msg->add_kludge("$FTN::Crypt::Constants::ENC_MESSAGE_KLUDGE: $method");
        $res->{msg} = $msg->get_message;
    } else {
        $res->{msg} = 'Message enccryption failed';
        return $res;
    }

    return $res;
}

#----------------------------------------------------------------------#
sub decrypt_message {
    my $self = shift;
    my (%opts) = @_;

    croak "No options specified" unless %opts;
    croak "No passphrase specified" unless defined $opts{Passphrase};

    my $msg = FTN::Crypt::Msg->new(
        Address => $opts{Address},
        Message => $opts{Message},
    );

    my $res = {
        ok => 0,
        msg => '',
    };

    my $method_used;
    foreach my $k (@{$msg->get_kludges}) {
        $method_used = $1 if $k =~ /^$FTN::Crypt::Constants::ENC_MESSAGE_KLUDGE:\s+(\w+)$/;
    }

    unless ($method_used) {
        $res->{msg} = "Message seems not to be encrypted";
        return $res;
    }

    my ($addr, $method) = $self->{nodelist}->get_email_addr($msg->get_address);
    unless ($addr) {
        $res->{msg} = 'Encryption-capable address not found';
        return $res;
    }

    if ($method ne $method_used) {
        $res->{msg} = "Message is encrypted with $method_used while node uses $method";
        return $res;
    }

    my ($in_fh, $out_fh, $err_fh, $pass_fh) = (IO::Handle->new(),
        IO::Handle->new(), IO::Handle->new(), IO::Handle->new());
     
    my $handles = GnuPG::Handles->new(
        stdin      => $in_fh,
        stdout     => $out_fh,
        stderr     => $err_fh,
        passphrase => $pass_fh,
    );

    my $pid = $self->{gnupg}->decrypt(handles => $handles);

    print $pass_fh $opts{Passphrase};
    close $pass_fh;

    print $in_fh $msg->get_text;
    close $in_fh;
    
    my $msg_dec = join '', <$out_fh>;
    close $out_fh;

    close $err_fh;

    waitpid $pid, 0;

    if ($msg_dec) {
        $res->{ok} = 1;
        $msg->set_text($msg_dec);
        $msg->remove_kludge($FTN::Crypt::Constants::ENC_MESSAGE_KLUDGE);
        $res->{msg} = $msg->get_message;
    } else {
        $res->{msg} = 'Message decryption failed';
        return $res;
    }

    return $res;
}

#----------------------------------------------------------------------#
sub _lookup_key {
    my $self = shift;
    my ($uid) = @_;
    
    my ($out_fh, $err_fh) = (IO::Handle->new(), IO::Handle->new());
     
    my $handles = GnuPG::Handles->new(
        stdout => $out_fh,
        stderr => $err_fh,
    );

    my $pid = $self->{gnupg}->list_public_keys(
        handles      => $handles,
        command_args => [$uid],
    );

    my $out = join '', <$out_fh>;

    close $out_fh;
    close $err_fh;

    waitpid $pid, 0;

    return $out ? 1 : 0;
}

#----------------------------------------------------------------------#
sub _import_key {
    my ($self, $uid) = @_;

    return 0 if $self->_lookup_key($uid);

    my $res;

    try {
        my $finger = PGP::Finger->new(
            sources => [
                PGP::Finger::Keyserver->new(
                    url => $self->{keyserver_url},
                ),
                #~ PGP::Finger::DNS->new(
                    #~ dnssec => 1,
                    #~ rr_types => ['OPENPGPKEY', 'TYPE61'],
                #~ ),
            ],
        );
        $res = $finger->fetch($uid);
    } catch {
        return 0;
    };

    if ($res) {
        my ($in_fh, $out_fh, $err_fh) = (IO::Handle->new(),
             IO::Handle->new(), IO::Handle->new());
         
        my $handles = GnuPG::Handles->new(
            stdin  => $in_fh,
            stdout => $out_fh,
            stderr => $err_fh,
        );

        my $pid = $self->{gnupg}->import_keys(handles => $handles);

        print $in_fh $res->as_string('armored');
        close $in_fh;

        close $out_fh;
        close $err_fh;

        waitpid $pid, 0;

        return 1;
    }

    return 0;
}

#----------------------------------------------------------------------#
sub _select_key {
    my ($self, $uid) = @_;

    return unless $self->_lookup_key($uid);

    my @keys;
    foreach my $key ($self->{gnupg}->get_public_keys($uid)) {
        push @keys, [$key->creation_date, $key->hex_id]
            if !$self->_key_is_disabled($key) && $self->_key_can_encrypt($key);
        foreach my $subkey (@{$key->subkeys_ref}) {
            push @keys, [$subkey->creation_date, $subkey->hex_id]
                if !$self->_key_is_disabled($subkey) && $self->_key_can_encrypt($subkey);
        }
    }

    @keys = map { '0x' . substr $_->[1], -8 }
            sort { $b->[0] <=> $a->[0] }
            @keys;
    
    return $keys[0];
}

#----------------------------------------------------------------------#
sub _key_is_disabled {
    my ($self, $key) = @_;

    return index($key->usage_flags, 'D') != -1;
}

#----------------------------------------------------------------------#
sub _key_can_encrypt {
    my ($self, $key) = @_;

    return index($key->usage_flags, 'E') != -1;
}

1;
__END__

=head1 NAME

FTN::Crypt - Encryption of the FTN messages.

=head1 SYNOPSIS

    use FTN::Crypt;

    $cr = FTN::Crypt->new(
        Nodelist => 'nodelist/NODELIST.*',
    );
    
    $cr->encrypt_message(
        Address => $ftn_address,
        Message => $msg_raw,
    );

=head1 DESCRIPTION

The possibility of FTN netmail encryption may be sometimes a useful option.
Corresponding nodelist flag was proposed in FSC-0073.

Although current FidoNet Policy (version 4.07 dated June 9, 1989) clearly
forbids routing of encrypted traffic without the express permission of
all the links in the delivery system, it's still possible to deliver such
messages directly. And, obviously, such routing may be allowed in FTN
networks other than FidoNet.

The proposed nodelist userflag is ENCRYPT:[TYPE], where [TYPE] is one of
'PGP2', 'PGP5', 'GnuPG'. So encryption-capable node should have something
like U,ENCRYPT:PGP5 in his nodelist record.

=head1 AUTHOR

Petr Antonov, E<lt>petr@antonov.spaceE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2019 by Petr Antonov

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl 5.10.0. For more details, see the full text
of the licenses at L<https://opensource.org/licenses/Artistic-1.0>, and
L<http://www.gnu.org/licenses/gpl-2.0.html>.

This package is provided "as is" and without any express or implied
warranties, including, without limitation, the implied warranties of
merchantability and fitness for a particular purpose.

=head1 INSTALLATION

Using C<cpan>:

    $ cpan FTN::Crypt

Manual install:

    $ perl Makefile.PL
    $ make
    $ make install

=head1 REFERENCES

=over 4

=item 1 L<FidoNet Policy Document Version 4.07|https://www.fidonet.org/policy4.txt>

=item 2 L<FTS-5001 - Nodelist flags and userflags|http://ftsc.org/docs/fts-5001.006>

=item 3 L<FSC-0073 - Encrypted message identification for FidoNet *Draft I*|http://ftsc.org/docs/fsc-0073.001>

=back 

=cut
(END)
