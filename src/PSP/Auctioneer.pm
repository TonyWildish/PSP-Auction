package PSP::Auctioneer;
use strict;
use warnings;

use base 'PSP::Util';
use PSP::Listener;
use HTTP::Status qw / RC_OK / ;
use POE;
use POE::Queue::Array;
use JSON::XS;

use Data::Dumper;
$Data::Dumper::Terse=1;
$Data::Dumper::Indent=0;

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my ($self,$help,%params,%args,%pLower);
  %args = @_;

  %params = (
          Me            => __PACKAGE__,
          Config        => undef,
          Log           => undef,
          Verbose       => 0,
          Debug         => 0,
          Logfile       => undef,
          Pidfile       => undef,
          ConfigPoll    => 3,

#         Manage the bidding machinery
          CurrentPort   => 0,
          Port          => 3141,
          Listening     => 0,

#         Parameters of the auction
          EqTimeout     => 15,  # How long with no bids before declaring equilibrium?
          Epsilon       =>  5,  # bid-fee
          Q             => 100, # How much of whatever I'm selling
        );

  $self = \%params;
  map { $pLower{lc $_} = $_ } keys %params;

  bless $self, $class;
  foreach ( keys %args ) {
    if ( exists $pLower{lc $_} ) {
      $self->{$pLower{lc $_}} = delete $args{$_};
    }
  }
  map { $self->{$_} = $args{$_} if $args{$_} } keys %args;
  die "No --config file specified!\n" unless defined $self->{Config};
  $self->ReadConfig(__PACKAGE__,$self->{Config});

  if ( $self->{Logfile} && ! $self->{Pidfile} ) {
    $self->{Pidfile} = $self->{Logfile};
    $self->{Pidfile} =~ s%.log$%%;
    $self->{Pidfile} .= '.pid';
  }
  $self->daemon() if $self->{Logfile};

  $self->{QUEUE} = POE::Queue::Array->new();

  POE::Session->create(
    object_states => [
      $self => {
        _start          => '_start',
        _default        => '_default',
        re_read_config  => 're_read_config',
      },
    ],
  );

  return $self;
}

sub PostReadConfig {
  my $self = shift;
  return if $self->{Port} == $self->{CurrentPort};
  if ( $self->{Listening} ) {
    $self->Log("Port has changed, stop/start listening");
    $self->StopListening();
  }
  $self->{CurrentPort} = $self->{Port};
  $self->StartListening();
}

sub StopListening {
  my $self = shift;
  $self->Log("Stub: StopListening");
}

sub StartListening {
  my $self = shift;
  $self->Log("Stub: StartListening on port ",$self->{Port});
  $self->{Listening} = 1;
  $self->{Listener} = PSP::Listener->new (
    Port => $self->{Port},
    # ContentHandler => {
    #   "/"         => sub { $self->{handleRoot}(@_) },
    #   "/bid"      => $self->{handleBid},
    #   "/hello"    => $self->{handleHello},
    #   "/goodbye"  => $self->{handleGoodbye},
    # }
  );
}

# sub handleRoot {
#   $DB::single=1;
#   my ($request, $response) = @_;
#   $response->code(RC_OK);
#   $response->push_header("Content-Type", "text/plain");
#   $response->content("Root handler:\n\n");
#   return RC_OK;
# }

# sub handleBid {
#   my ($request, $response) = @_;
#   $response->code(RC_OK);
#   $response->push_header("Content-Type", "text/plain");
#   $response->content("Bid handler:\n\n");
#   return RC_OK;
# }

# sub handleHello {
#   my ($request, $response) = @_;
#   $response->code(RC_OK);
#   $response->push_header("Content-Type", "text/plain");
#   $response->content("Hello handler:\n\n");
#   return RC_OK;
# }

# sub handleGoodbye {
#   my ($request, $response) = @_;
#   $response->code(RC_OK);
#   $response->push_header("Content-Type", "text/plain");
#   $response->content("Goodbye handler:\n\n");
#   return RC_OK;
# }

1;
