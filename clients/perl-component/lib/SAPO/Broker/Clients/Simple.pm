package SAPO::Broker::Clients::Simple;

use Carp qw(carp croak);

use SAPO::Broker;
use SAPO::Broker::Messages;
use SAPO::Broker::Clients::Minimal;
use SAPO::Broker::Transport::TCP;
use SAPO::Broker::Transport::UDP;
use SAPO::Broker::Codecs::Thrift;

#don't fail if SSL is not a viable transport (please install IO::Socket::SSL)
my $has_ssl = SAPO::Broker::has_ssl();

if ($has_ssl) {
    use SAPO::Broker::Transport::SSL;
}

use strict;
use warnings;

our %DEFAULT_OPTIONS = ( 'proto' => 'tcp' );
our @ISA = qw(SAPO::Broker::Clients::Minimal);

sub new {
    my ( $pack, %options ) = @_;

    %options = ( %DEFAULT_OPTIONS, %options );

    my $codec     = SAPO::Broker::Codecs::Thrift->new();
    my $transport = __get_transport_class(%options)->new(%options);

    my $self = $pack->SUPER::new(
        'codec'     => $codec,
        'transport' => $transport,
    );

    $self->{'auto_ack'} = {};

    return $self;

}

sub __get_transport_class {
    my (%options) = @_;

    my $proto  = lc( $options{'proto'} );
    my $prefix = 'SAPO::Broker::Transport::';

    if ( $proto eq 'tcp' ) {
        return $prefix . 'TCP';
    } elsif ( $proto eq 'udp' ) {
        return $prefix . 'UDP';
    } elsif ( $has_ssl and $proto eq 'ssl' ) {
        return $prefix . 'SSL';
    } else {
        croak("Unknown protocol '$proto'");
        return;
    }
}

sub __can_acknowledge($) {
    my ($kind) = @_;
    return $kind eq 'QUEUE' or $kind eq 'VIRTUAL_QUEUE';
}

sub subscribe {
    my ( $self, %options ) = @_;

    my $subscribe = SAPO::Broker::Messages::Subscribe->new(%options);
    my $ret       = $self->send($subscribe);

    if ( __can_acknowledge( $options{'destination_type'} ) and $options{'auto_acknowledge'} ) {

        #add the queue name to the auto_ack queue
        $self->{'auto_ack'}->{ $options{'destination'} } = '+inf';    #acknowledge all messages
    }

    return $ret;
}

sub poll {
    my ( $self, %options ) = @_;
    my $poll = SAPO::Broker::Messages::Poll->new(
        'timeout' => 0,
        %options
    );
    my $ret = $self->send($poll);

    if ( $options{'auto_acknowledge'} ) {
        $self->{'auto_ack'}->{ $options{'destination'} } += 1;
    }
    return $ret;
}

sub acknowledge {
    my ( $self, $notification ) = @_;

    my $id          = $notification->message->id;
    my $destination = $notification->destination;
    my $ack         = SAPO::Broker::Messages::Acknowledge->new(
        'message_id'  => $id,
        'destination' => $destination
    );
    return $self->send($ack);
}

sub publish {
    my ( $self, %options ) = @_;

    if ( exists( $options{'payload'} ) ) {
        my $message = SAPO::Broker::Messages::Message->new(%options);
        my $publish = SAPO::Broker::Messages::Publish->new( %options, 'message' => $message );
        return $self->send($publish);
    } else {
        carp("no payload to publish");
        return $self;
    }
}

sub authenticate {
    my ( $self, $username, $password ) = @_;

    if ( defined($username) and defined($password) ) {
        my $auth = SAPO::Broker::Messages::Authentication::from_sts_credentials(
            'username' => $username,
            'password' => $password
        );
        return $self->send($auth);
    } else {
        croak "username and password mandatory";
    }
}

sub receive {
    my ($self) = @_;

    #get the actual message from the base class
    my $message = $self->SUPER::receive();

    #now check the message type
    #if it is a fault just raise an exception

    my $msg_type = ref($message);

    if ( $msg_type eq 'SAPO::Broker::Messages::Fault' ) {
        use Data::Dumper;
        warn Dumper($message);
        warn __PACKAGE__ . " " . $message->fault_message;
        die $message;

        #otherwise return the message with no modification
    } elsif ( $msg_type eq 'SAPO::Broker::Messages::Notification' ) {

        #try to find whether we need to acknowledge
        my $auto_ack_count = \$self->{'auto_ack'}->{ $message->destination };
        if ( __can_acknowledge( $message->destination_type ) and defined($$auto_ack_count) and $$auto_ack_count > 0 ) {
            $self->acknowledge($message);
            --$$auto_ack_count;
        }
        return $message;
    } else {
        return $message;
    }

} ## end sub receive

1;
