package DJabberd::Connection::ServerBiDi;
use strict;
use base 'DJabberd::Connection::ServerIn';
use DJabberd::Connection::ServerOut;
# below doesn't work due to fields pragma
#use base qw(DJabberd::Connection::ServerIn DJabberd::Connection::ServerOut);
#use mro 'c3';

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

sub new {
    my $class = shift;
    if($#_ == 1 && ref($_[0])) {
	return $class->SUPER::new(@_);
    } else {
	return DJabberd::Connection::ServerOut::new($class,@_);
    }
}
# Use functionality of In and Out on same socket - according to XEP-0288
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

sub start_stream_back {
    my $self = shift;
    $self->{bidi} = BIDI_UNKNOWN;
    $self->SUPER::start_stream_back(@_, features => "<bidi xmlns='urn:xmpp:features:bidi'/>");
}
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

sub on_stream_start {
    my $self = shift;
    my ($ss) = @_;
    # Client will enable that explicitly when sending bidi,
    # server resets to unknown when sending features
    $self->{bidi} = BIDI_DISABLE;
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

sub set_rcvd_features {
    my $self = shift;
    $self->SUPER::set_rcvd_features(@_);
    my ($bidi) = grep{$_->element eq '{urn:xmpp:features:bidi}bidi'}$_[0]->children_elements;
    if($bidi && $self->{queue}) {
	$self->log->debug("Peer supports BIDI on conn ".$self->{id}.", enabling");
	$self->write(qq{<bidi xmlns='urn:xmpp:bidi'/>});
	$self->{bidi} = BIDI_CLIENT;
    }
    DJabberd::Connection::ServerOut::on_stream_start($self,$self->{in_stream}) if(ref($self->{in_stream}));
}

sub on_stanza_received {
    my $self = shift;
    my ($node) = @_;
    if($node->element eq "{urn:xmpp:bidi}bidi" && $self->{bidi} == BIDI_UNKNOWN) {
	$self->log_incoming_data($node);
	$self->{bidi} = BIDI_SERVER;
    } elsif(ref($self->{queue}) && ($self->{bidi} == BIDI_DISABLE or $node->element eq "{jabber:server:dialback}result")) {
	# If queue is set we're either bidi or out (client). For bidi we need only db:result, otherwise we're pure out
	if($node->element eq "{jabber:server:dialback}result" && $node->attr('{}type') eq 'valid') {
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
*on_connected = \&DJabberd::Connection::ServerOut::on_connected;
*event_write = \&DJabberd::Connection::ServerOut::event_write;
*event_hup = \&DJabberd::Connection::ServerOut::event_hup;
1;
