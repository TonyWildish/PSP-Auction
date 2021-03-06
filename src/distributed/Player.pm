package PSP::Player;
use strict;
use warnings;

use HTTP::Status qw / :constants / ;
use base 'PSP::Util', 'PSP::Session';
use PSP::Listener;
use POE;
use JSON::XS;
use LWP::UserAgent;

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
          Test          => undef,
          Pidfile       => undef,
          ConfigPoll    => 300,

#         Manage the bidding machinery
          CurrentPort   => 0,
          Port          => 3141,
          Listening     => 0,
          HandlerNames  => [
            'hello',
            'goodbye',
            'offer',
            'allocation',
          ],
          NCycles       => 1,

          Epsilon       => undef,  # bid-fee
          Q             => undef, # How much of whatever is being sold

          Strategy      => 'Random',

          POE_Trace     => 0,
          POE_Debug     => 0,
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
  die "No --name specified!\n" unless defined $self->{Me};
  $self->ReadConfig($self->{Me},$self->{Config});

  map { $self->{Handlers}{$_} = 1 } @{$self->{HandlerNames}};

  $self->{Strategies} = {
    'Random'        => 'StrategyRandom',
    'Fixed'         => 'StrategyFixed',
    'Interactive'   => 'StrategyInteractive',
    'Optimal'       => 'StrategyOptimal',
    'List'          => 'StrategyList',
  };

  if ( $self->{Log} && ! $self->{Pidfile} ) {
    $self->{Pidfile} = $self->{Log};
    $self->{Pidfile} =~ s%.log$%%;
    $self->{Pidfile} .= '.pid';
  }
  $self->daemon() if $self->{Log};

  POE::Session->create(
    object_states => [
      $self => {
        _start          => '_start',
        _stop           => '_stop',
        _child          => '_child',
        _default        => '_default',
        re_read_config  => 're_read_config',
        ContentHandler  => 'ContentHandler',
        ErrorHandler    => 'ErrorHandler',

        SendHello       => 'SendHello',
        SendBid         => 'SendBid',
      },
    ],
  )->option( trace => $self->{POE_Trace}, debug => $self->{POE_Debug} );;

  return $self;
}

sub start {
  my $self = shift;

  if ( $self->{Test} ) {
    $self->test();
    exit 0;
  }
}

sub PostReadConfig {
  my $self = shift;
  return if $self->{Port} == $self->{CurrentPort};
  if ( $self->{Listening} ) {
    $self->Log('Port has changed, stop/start listening');
    $self->StopListening();
  }
  $self->{CurrentPort} = $self->{Port};

  my $strategy = $self->{Strategies}{$self->{Strategy}};
  if ( !defined($strategy) ) {
    die 'No handler for strategy ',$self->{Strategy},"\n";
  }
  $self->{StrategyHandler} = $self->can($strategy);

  $self->{MaxBids} = 5;
  if ( $self->{NBids} ) { $self->{MaxBids} = $self->{NBids}; }
  $self->{NBids} = $self->{MaxBids};

# Cheat by setting these from the config file.
# Should really ask the auctioneer for them instead...
  foreach ( qw / EqTimeout Epsilon Q / ) {
    $self->{$_} = $PSP::Auctioneer{$_};
  }
  $self->StartListening();

  $self->{server} = 'http://' .
                    $self->{AuctioneerHost} . ':' .
                    $self->{AuctioneerPort} . '/' .
                    $self->{Me} . '/';

  $self->Log($self->{Me},': Start bidding!');
  POE::Kernel->yield('SendHello');
}

sub SendHello {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  my $data = {
      player => $self->{Me},
      url => 'http://' . $self->{Host} . ':' . $self->{Port} . '/'
    };
  my $response = $self->get( { api => 'hello', data => $data } );
  $self->Log('SendHello... OK');
  $self->Log('Start placing bids');
  $kernel->yield('SendBid');
}

# Handlers for the interaction with the auctioneer
sub hello {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  # $self->Log('Hello handler...');
}

sub goodbye {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  $self->Log('Goodbye handler...');
}

sub offer {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  my $offer = $args->{$self->{Me}};
  $self->Log('Got offer: (a=',$offer->{a},',c=',$offer->{c},')');
  $kernel->delay_set('SendBid',rand()*2.5+1);
  $self->{allocation} = $args;
}

sub allocation {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  my $offer = $args->{$self->{Me}};

  $self->Log('Got allocation: (a=',$offer->{a},',c=',$offer->{c},')');
  $self->{NCycles}--;
  if ( !$self->{NCycles} ) {
    print "Game over :-)\n";
    exit 0;
  }
  $kernel->delay_set('SendBid',10+3*rand());
  $self->{allocation} = $args;

  $self->{NBids} = int( rand() * $self->{MaxBids} ) + 1;
  print "\n";
}

# implement my own strategy
sub SendBid {
  my ($self,$kernel) = @_[ OBJECT, KERNEL ];
  my ($bid,$response,$strategy);

  if ( $self->{NBids}-- <= 0 ) {
    $self->Log("I'm happy now :-)") if $self->{NBids} == 0;
    return;
  }

  return unless $bid = $self->{StrategyHandler}->($self);
  $self->{Bid} = $bid;
  $self->Dbg('Bid: (q=',$bid->{q},',p=',$bid->{p},')',' (NBids = ',$self->{NBids},')');
  $response = $self->get({ api => 'bid', data => $bid });
  $self->Log('Bid: (q=',$bid->{q},',p=',$bid->{p},')',' (NBids = ',$self->{NBids},') OK');
}

# Strategies...
sub StrategyRandom {
  my $self = shift;
  my $bid = { q => int(rand($self->{Q})), p => int(rand(5)+3) };
  return $bid;
}

sub StrategyFixed {
  my $self = shift;
  my $bid = $self->{Bid};
  $bid = { q => 50, p => 10 } unless $bid;
  return $bid;
}

sub StrategyList {
  my $self = shift;
  my $bid = shift @{$self->{Bids}};
  return $bid;
}

sub StrategyInteractive {
  my $self = shift;
  my ($p,$q);
  print "q=?  > "; $q = <STDIN>; chomp($q);
  print "p=?  > "; $p = <STDIN>; chomp($p);
  print 'Read (q=',$q,',','p=',$p,")\n";
  return { q => $q, p => $p };
}

sub StrategyOptimal {
  my $self = shift;
  my ($theta,$thetap,$utility,$k,$qbar,$m,$allocation,$A,$C);
  my (@players,$offer,$qmax,$qstar,$pstar,$cmax);

  $pstar = 0; # TW $self->{Epsilon};
  $qstar = $self->{Valuation}{qbar};
  if ( ! $self->{allocation} ) { return { q => $qstar, p => $pstar }; }

  $allocation = $self->{allocation}{$self->{Me}};
  $A = $allocation->{a};
  $C = $allocation->{c};

  $k    = $self->{Valuation}->{k};
  $qbar = $self->{Valuation}->{qbar};
  $m    = PSP::Util::min($A,$qbar);

  $theta = -$k * $m * $m / 2 + $k * $qbar * $m;
  $utility = $theta - $C;
  $self->Log("(k=$k,qbar=$qbar), a=$A, c=$C, theta=$theta, utility=$utility");

# The truthful epsilon-best reply (q*,p*) has q* such that:
# q+eps > theta'(q*) and q-eps < theta'(q*)
#
# and has p* = theta'(q*)
#
# My theta is -k . a^2 / 2 for a < qbar, and k . qbar^2 / 2 for a >= qbar
# theta' is therefore k . ( qbar - a ) for a < qbar and zero above qbar
#
# Find q* by examining all allocations at prices from lowest cost upwards
# When one of the costs crosses my theta' at the total allocated amount
# so far, that value of q is my q*
#
# There is an edge-case, where the allocation-staircase does not cross theta'
# because the total amount being allocated is too low. In that case I can increase
# the quantity I ask for by the amount unallocated, providing it doesn't exceed
# the point where my theta' drops to zero

# Qbar(y,s-i) = Q - sum [p>=y, k!=i] q_k

  $qmax = $cmax = $thetap = 0;
  print Dumper($self->{allocation}),"\n";
  @players = sort {
    $self->{allocation}{$a}->{c} <=> $self->{allocation}{$b}->{c}
  } keys %{$self->{allocation}};

  foreach ( @players ) {
    next if $_ eq $self->{Me};
    $offer = $self->{allocation}{$_};
    $cmax  = $offer->{c};
    last if $cmax > $C;
    $qmax += $offer->{a};
    $thetap = $k * ($qbar - $qmax);
    # print "thetap=$thetap, cmax=$cmax, qmax=$qmax, offer=(c=",$offer->{c},",a=",$offer->{a},")\n";
    if ( $thetap >= $offer->{c} ) {
      $qstar = $qmax;
      $pstar = $thetap;
# TW      if ( $pstar < $self->{Epsilon} ) { $pstar = $self->{Epsilon}; }
      if ( $pstar < 0 ) { $pstar = 0; }
    }
    # print "pstar=$pstar, qstar=$qstar\n";
  }

# Deal with the edge-case...
  if ( $thetap >= $cmax ) {
    # $self->Log("Deal with the edge case (theta'=$thetap, cmax=$cmax)");
    $qstar = $qbar;
    $pstar = 0; # TW $self->{Epsilon};
  }

# calculate the epsilon-best reply
$DB::single=1;
  $qstar -= $self->{Epsilon}/($k * $qbar);
  $pstar = $k * ( $qbar - $qstar );

$DB::single=1;
  $self->Log("Optimal bid: (q=$qstar,p=$pstar)");
  if ( $self->{Bid} &&
       $pstar == $self->{Bid}{p} &&
       $qstar == $self->{Bid}{q} ) { return; }
  return { p => $pstar, q => $qstar };
}

sub test {
  my $self = shift;
  my $bid;

  $self->{Epsilon} = 5;
  $self->{Me} = 'player1';
  $self->{Q} = 100;

  print "\n1)";
  $self->{allocation} = {
    player1 => { a => 30, c => $self->{Epsilon} },
    player2 => { a => 30, c => $self->{Epsilon} },
  };
  $self->{Valuation} = { k => 0.5, qbar => 70 };
  $bid = $self->StrategyOptimal();
  $self->expect($bid,{ p => $self->{Epsilon}, q => 70 });

  print "\n2)";
  $self->{allocation} = {
    player1 => { a => 70, c => $self->{Epsilon} },
    player2 => { a => 30, c => $self->{Epsilon} },
  };
  $self->{Valuation} = { k => 0.5, qbar => 70 };
  $bid = $self->StrategyOptimal();
  $self->expect($bid,{ p => $self->{Epsilon}, q => 70 });

  print "\n3)";
  $self->{allocation} = {
    player1 => { a => 70, c => $self->{Epsilon} },
    player2 => { a => 30, c => $self->{Epsilon} },
  };
  $self->{Valuation} = { k => 0.5, qbar => 80 };
  $bid = $self->StrategyOptimal();
  $self->expect($bid,{ p => $self->{Epsilon}, q => 80 });

  print "\n ** Congratulations, all tests passed ** \n\n";
}

sub expect {
  my ($self,$got,$expect) = @_;
  my ($player,$a,$c,$A,$C,$errors);
  $errors = 0;

  if ( $got->{p} != $expect->{p} ) {
    $errors++;
    print "Expected price = ",$expect->{p},". got ",$got->{p},"\n";
  }
  if ( $got->{q} != $expect->{q} ) {
    $errors++;
    print "Expected quantity = ",$expect->{q},". got ",$got->{q},"\n";
  }
  die "\n *** Abort with $errors errors ***\n\n" if $errors;
  print "OK!\n\n";
}


1;
