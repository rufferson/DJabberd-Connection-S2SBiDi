
use strict;
use warnings;
use Test::More tests => 3;

#use Danga::Socket;
use DJabberd;
use DJabberd::IQ;
use DJabberd::DNS;
use DJabberd::VHost;

my $class = "DJabberd::Connection::ServerBiDi";
use_ok($class);

#my $domain = "ruff.mobi";
#my $dother = "xmpp.org";
#my $dother = "lightwitch.org";

my $domain = "example.com";
my $dother = "example.net";
my $s=DJabberd->new();
$s->set_config_s2sclienttransport($class);
$s->set_config_s2sservertransport($class);
$s->set_fake_s2s_peer($domain,DJabberd::IPEndPoint->new('::1',5269));
$s->set_fake_s2s_peer($dother,DJabberd::IPEndPoint->new('::1',5269));
$s->start_s2s_server;
my $vc=DJabberd::VHost->new(server_name=>$domain,require_ssl=>1,s2s=>1);
my $vs=DJabberd::VHost->new(server_name=>$dother,require_ssl=>1,s2s=>1);
$s->add_vhost($vc);
$s->add_vhost($vs);

my ($oid,$fid,$rid,$cid) = (555, -1, -1, -1);
my $fiq = DJabberd::IQ->new('','iq',{'{}from'=>$domain,'{}to'=>$dother,'{}type'=>'get','{}id'=>$oid++},[ DJabberd::XMLElement->new('','query', {'{}xmlns'=>'http://jabber.org/protocol/disco#info'})]);
my $riq = DJabberd::IQ->new('','iq',{'{}from'=>$dother,'{}to'=>$domain,'{}type'=>'get','{}id'=>$oid++},[ DJabberd::XMLElement->new('','query', {'{}xmlns'=>'http://jabber.org/protocol/disco#info'})]);
my $run = 2;
my $tmr = Danga::Socket->AddTimer(5,sub {
     $run = 0;
});
my $handler = sub {
    my ($vh, $cb, $iq) = @_;
    if($iq->isa('DJabberd::IQ') && $iq->signature eq 'result-{http://jabber.org/protocol/disco#info}query') {
	$run--;
	$riq->deliver($vs) if($run==1);
	if($run==1) {
	    $fid = $iq->attr('{}id');
	} elsif($run==0) {
	    $rid = $iq->attr('{}id');
	    $tmr->cancel;
	}
	return $cb->stop_chain;
    }
    $cb->decline;
};
$vc->register_hook("switch_incoming_server",$handler);
$vs->register_hook("switch_incoming_server",$handler);

$fiq->deliver($vc);

Danga::Socket->SetPostLoopCallback(sub {
    return $run;
});
Danga::Socket->EventLoop();
ok($fid == $oid - 2, "IQ Result received for forward disco request");
ok($rid == $oid - 1, "IQ Result received for reverse disco request");
