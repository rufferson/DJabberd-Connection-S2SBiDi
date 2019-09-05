package DJabberd::Connection::ServerBiDi;
use strict;
use base 'DJabberd::Connection::ServerIn';
use DJabberd::Connection::ServerOut;
# below doesn't work due to fields pragma
#use base qw(DJabberd::Connection::ServerIn DJabberd::Connection::ServerOut);
#use mro 'c3';
use DJabberd::SASL::Connection::External;

use fields (
	'bidi',
     # These are for ServerIn
     #'announced_dialback',
     #'verified_remote_domain',  # once we know it
     # And these are of ServerOut
        'state',
        'queue',  # our DJabberd::Queue::ServerOut
);
use constant {
	BIDI_DISABLE => -1,
	BIDI_UNKNOWN =>  0,
	BIDI_CLIENT  =>  1,
	BIDI_SERVER  =>  2,
};

=head1 NAME

DJabberd::Connection::ServerBiDi - Bidirectional Server-to-Server Connections [XEP-0288]

=head1 VERSION

Version 0.0.1
=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

The extension implements Bidirectional S2S Connection [XEP-0288] to allow using
single connection for egress and ingress streams.

  S2SServerTransport DJabberd::Connection::ServerBiDi
  S2SClientTransport DJabberd::Connection::ServerBiDi

Implementation is using ServerIn and ServerOut classes for actual stream processing
merely adding some sugar to follow sematics of XEP-0288. That means it will use
same authentication mechanisms as normal unidirectional stream. Although since
those classes are using dialback only, the implementation is also bound to dialback
processing.

If BiDi connection is enabled while there's existing ServerOut connection - it
will abort existing connection with <conflict/> stream error and replace it.

ServerIn connections are unbound so there's no way to replace them - this however
should be handled by remote side.

=head1 METHODS

=head2 new(...)

Based on type of arguments (%hash or (sock,server) pair) will call either
ServerIn->new($sock,$server) or ServerOut->new(%hash) constructor to initialize
ServerBiDi object either way. This is to allow transport to be used as drop-in
replacement of the corresponding built-in classes.

=cut

sub new {
    my $class = shift;
    if($#_ == 1 && ref($_[0])) {
	return $class->SUPER::new(@_);
    } else {
	return DJabberd::Connection::ServerOut::new($class,@_);
    }
}
# Use functionality of In and Out on same socket - according to XEP-0288.
# All the dancing around {bidi} state is to prevent enablement of the bidi
# by out-of-phase <bidi> nonza (thus breaking delivery)
#
# Event flow: 
# Incoming:
# < S2S Client connects and starts stream - set bidi to DISABLE
# > We advertise bidi stream feature along with tls
# < S2S Client starts TLS
# > We proceed it
# < S2S Client re-starts stream - stream_start - again to disabled
# > We re-advertise bidi - bidi set to UNKNOWN (remains disabled if we dont advertise)
# < S2S Client enables bidi
# = We handle it and - we set bidi to SERVER mode if it is UNKNOWN
# < S2S Client sends us dialback key 
# = We spinoff DialBack connection to validate the key - set bidi to DISABLE if still UNKNOWN
# > We send dialback result: We know client is valid, client explicitly trusts us
# = Find existing or create new Out queue for the domain. Err-conflict existing connection.
# = Attach Out queue to ourself and call its on_connected to activate S2S delivery
#

=head2 on_connected

Override ServerOut::on_connected - we need to provide at least 'from' attribute
=cut
sub on_connected {
    my $self = shift;
    $self->set_to_host($self->{queue}->{domain});
    $self->start_init_stream(extra_attr => "xmlns:db='jabber:server:dialback' from='".$self->{vhost}->server_name."'",
                             to         => $self->to_host);
    $self->watch_read(1);
}

=head2 start_stream_back

This ServerIn overriden method will add <bidi/> stream feature to the back stream.
=cut

sub start_stream_back {
    my $self = shift;
    # Don't add feature if BiDi is already established
    return $self->SUPER::start_stream_back(@_) if($self->{bidi} == BIDI_SERVER || $self->{bidi} == BIDI_CLIENT);
    # Otherwise reset the state and add feature to the stream start
    $self->{bidi} = BIDI_UNKNOWN;
    $self->SUPER::start_stream_back(@_, features => "<bidi xmlns='urn:xmpp:features:bidi'/>");
}

=head2 dialback_result_valid

This ServerIn overriden method will put a period on bidi negotiation. If negotiation
was successfull - it will enable egress stream by attaching itself to the S2S Queue.

At this point if there's existing queue with existing connection - the connection
will be replaced by the current one, while old connection will be aborted.

If no bidi is negotiated - bidi will be permanenetly switched off on this connection
and it will continue working as normal ServerIn connection.

=cut
sub dialback_result_valid {
    my $self = shift;
    $self->SUPER::dialback_result_valid(@_);
    if($self->{bidi} != BIDI_SERVER) {
    	$self->{bidi} = BIDI_DISABLE;
	return;
    }
    my %opts = @_;
    my $domain = $opts{orig_server};
    $self->log->debug("Passed DB auth for BIDI conn ".$self->{id}."[".$self->{bidi}."] from $domain");
    $self->log->info("Enabling BiDi connection on ".$self->{id}." from $domain for ".$self->vhost->name);
    $self->{queue} = $self->vhost->find_queue($domain);
    if($self->{queue}) {
	if($self->{queue}->{connection}) {
	    my $c = $self->{queue}->{connection};
	    $self->{queue}->{connection} = undef;
	    $self->{queue}->{state} = DJabberd::Queue::NO_CONN;
	    $c->stream_error("conflict","Superseding by BIDI connection $domain") if(!$c->{closed} && $c->{in_stream});
	}
    } else {
    	$self->{queue} = DJabberd::Queue::ServerOut->new(
	    		source => "bidi",
			vhost  => $self->vhost,
	   		domain => $domain,
		    );
	$self->vhost->add_queue($domain, $self->{queue});
    }
    Scalar::Util::weaken($self->{queue});
    $self->{queue}->set_connection($self);
    $self->{queue}->on_connection_connected($self);
    # Ready to serve. Now what?
}

# Outgoing:
# = S2S Deliver creates a ServerOut Queue (Delivery::S2S)
# = S2S Deliver enqueues a stanza which triggers conneciton (Queue)
# > We connect and start the stream - bidi set to DISABLE
# < Server sends us stream features with bidi and starttls
# > We send starttls request TODO (Optional)
# < Server sends us Proceed confirmation TODO (Optional)
# > We re-start the stream - bidi set to DISABLE
# < Server sends us features with bidi
# > We send <bidi> initiation - set BIDI to CLIENT
# > We send dialback key
# < Server sends valid dialback result
# = We are done, inherited ServerIn part will handle incoming stanzas
#

=head2 on_stream_start

This method overrides both ServerIn and ServerOut. If current connection is
constructed as ServerIn - it will patch through to it. Otherwise for ServerOut
it will delay the stream_back and hence dialback till features processing.

If however stream version is below 1.0 and hence features are optional - it
will also pass through to ServerOut parent method.
=cut

sub on_stream_start {
    my $self = shift;
    my ($ss) = @_;
    # Client will enable that explicitly when sending bidi,
    # server resets to unknown when sending features
    $self->{bidi} = BIDI_DISABLE if($self->{bidi} != BIDI_SERVER && $self->{bidi} != BIDI_CLIENT);;
    if(ref($self->{queue})) { # Out
	if($ss->version->supports_features) {
    	    # Delay the dialback until features are seen
	    $self->{in_stream} = $ss;
	    $self->log->debug("Waiting for features to discover BIDI support");
	} else {
	    # Features not mandatory, start now
	    $self->log->debug("Protocol version too old for BIDI support, fallback to ServerOut");
	    DJabberd::Connection::ServerOut::on_stream_start($self,@_);
	}
    } else { # In
	$self->SUPER::on_stream_start(@_);
    }
}

=head2 set_rcvd_features

This ServerOut overriden method checks the stream features and will enable bidi
feature by sending corresponding <bidi/> nonza. Even though ingress stream is
enabled at this point, actual enablement happens as part of dialback
verification process, hence ServerIn implementation will abort the stream if any
stanza comes in before dialback process is complete.
=cut

sub set_rcvd_features {
    my $self = shift;
    $self->SUPER::set_rcvd_features(@_);
    my ($tls) = grep{$_->element eq '{urn:ietf:params:xml:ns:xmpp-tls}starttls'}$_[0]->children_elements;
    $self->log->debug("Got features ".join(', ',map{"".$_->element}$_[0]->children_elements));
    # Whether it is <required/> or <not/> - we want to <starttls/>
    if($tls && $self->vhost->server->ssl_cert_file && $self->vhost->server->ssl_private_key_file) {
	$self->{in_stream} = 'starttls';
	my $xml = "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>";
	$self->log_outgoing_data($xml);
	$self->write(\$xml);
	return; # We'll end up with new stream or closed connection anyway
    }
    my ($bidi) = grep{$_->element eq '{urn:xmpp:features:bidi}bidi'}$_[0]->children_elements;
    if($bidi && $self->{queue} && $self->{bidi} < BIDI_CLIENT) {
	$self->log->debug("Peer supports BIDI on conn ".$self->{id}.", enabling");
	$self->write(qq{<bidi xmlns='urn:xmpp:bidi'/>});
	$self->{bidi} = BIDI_CLIENT;
    }
    my ($sasl) = grep{$_->element eq '{urn:ietf:params:xml:ns:xmpp-sasl}mechanisms'}$_[0]->children_elements;
    if($sasl && $sasl->first_element && $sasl->first_element->element_name eq 'mechanism' && $sasl->first_element->first_child eq 'EXTERNAL' && $self->{ssl}) {
	# SASL External over TLS should be preferred to Dialback.
	$sasl = DJabberd::SASL::Connection::External->new($self);
	$self->log->debug("Peer supports SASL on conn ".$self->{id}.", ".$self->{sasl});
	if($sasl && ($sasl->res() == &Net::SSLeay::X509_V_OK)) {
	    my $xml = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='EXTERNAL'>=</auth>";
	    $self->log_outgoing_data($xml);
	    $self->write(\$xml);
	    return; # Also will restart if succeeds
	}
    }
    if($self->{ssl} && $self->{sasl} && $self->{in_stream}) {
	# We're fully loaded for s2s-out, kick on
	$self->{queue}->on_connection_connected($self);
	return;
    }
    DJabberd::Connection::ServerOut::on_stream_start($self,$self->{in_stream}) if(ref($self->{in_stream}));
}

=head2 on_stanza_received

This method overrides both parent classes and will call either of them depending
on how the object was constructed and whether bidi is enabled. It will also
explicitly handle incoming <bidi/> nonza to enable the bidi for ServerIn.
Since the same method is used for dialback processing of the ServerOut class -
it will also hook into this process to register remote domain for ingress stream.
=cut

sub on_stanza_received {
    my $self = shift;
    my ($node) = @_;
    if($node->element eq "{urn:xmpp:bidi}bidi" && $self->{bidi} == BIDI_UNKNOWN) {
	$self->log_incoming_data($node);
	$self->{bidi} = BIDI_SERVER;
    } elsif($node->element eq '{urn:ietf:params:xml:ns:xmpp-tls}proceed' && !$self->ssl && $self->{in_stream} eq 'starttls') {
	    my $tls = DJabberd::Stanza::StartTLS->downbless($node, $self);
	    $self->filter_incoming_server_builtin($tls);
	    $self->on_connected;
    } elsif($node->element eq '{urn:ietf:params:xml:ns:xmpp-sasl}success' || $node->element eq '{urn:ietf:params:xml:ns:xmpp-sasl}failure') {
	# SASL Handler
	if($node->element_name eq 'success') {
	    $self->log->debug($self->{id}." authenticated. No need for dialback.");
	    $self->peer_domain_set_verified($self->to_host) if($self->{bidi} == BIDI_CLIENT);
	    $self->restart_stream();
	    $self->on_connected();
	    # Nothing to wait for actually but need to follow the script
	} else {
	    $self->{sasl} = undef;
	    $self->log->info("SASL Autnetication failed: ".$node->innards_as_xml);
	    #$self->close();
	    # Fallback to classic dialback
	    DJabberd::Connection::ServerOut::on_stream_start($self,$self->{in_stream}) if(ref($self->{in_stream}));
	}
    } elsif(ref($self->{queue}) && ($self->{bidi} == BIDI_DISABLE or $node->element eq "{jabber:server:dialback}result")) {
	# If queue is set we're either bidi or out (client). For bidi we need only db:result, otherwise we're pure out
	if($node->element eq "{jabber:server:dialback}result" && $node->attr('{}type') eq 'valid' && $self->{bidi} != BIDI_DISABLE) {
	    my $dom = $node->attr('{}from');
	    if($dom eq $self->{queue}->{domain}) {
    	        $self->{verified_remote_domain}->{lc $dom} = $dom;
		$self->log->debug("Implicitly authenticating '$dom' for outgoing connection ".$self->{id});
	    } else {
		$self->stream_error('invalid-from',"DialbackResult from $dom is not acceptable");
		return;
	    }
	}
	DJabberd::Connection::ServerOut::on_stanza_received($self,@_);
    } else {
	# In all other cases we're either pure in or bidi so can handle normal incoming flow
	$self->SUPER::on_stanza_received(@_);
    }
}

sub event_err {
    my $self = shift;
    return DJabberd::Connection::ServerOut::event_err($self) if($self->{queue});
    return $self->SUPER::event_err;
}

sub close {
    my $self = shift;
    return if($self->{closed});
    DJabberd::Connection::ServerOut::close($self) if($self->{queue});
    return $self->SUPER::close;
}

# Imitate multi-inheritence - add missing calls from ServerOut
*start_connecting = \&DJabberd::Connection::ServerOut::start_connecting;
#*on_connected = \&DJabberd::Connection::ServerOut::on_connected;
*event_write = \&DJabberd::Connection::ServerOut::event_write;
*event_hup = \&DJabberd::Connection::ServerOut::event_hup;

=head1 AUTHOR

Ruslan N. Marchenko, C<< <me at ruff.mobi> >>

=head1 COPYRIGHT & LICENSE

Copyright 2016 Ruslan N. Marchenko, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.
=cut

1;
