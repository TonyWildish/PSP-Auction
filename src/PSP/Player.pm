package PSP::Player;
use strict;
use warnings;

use base 'PSP::Util';
use POE;

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
          Verbose       => 0,
          Debug         => 0,
          Test          => undef,
          Auctioneer    => 'PSP::Auctioneer',

          NCycles       => 1,

          Epsilon       => undef, # bid-fee
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

  $self->{Strategies} = {
    'Random'        => 'StrategyRandom',
    'Fixed'         => 'StrategyFixed',
    'Interactive'   => 'StrategyInteractive',
    'Optimal'       => 'StrategyOptimal',
    'SpendBudget'   => 'StrategySpendBudget',
    'List'          => 'StrategyList',
  };

  if ( $self->{Log} && ! $self->{Pidfile} ) {
    $self->{Pidfile} = $self->{Log};
    $self->{Pidfile} =~ s%.log$%%;
    $self->{Pidfile} .= '.pid';
  }
  # $self->daemon() if $self->{Log};

  POE::Session->create(
    object_states => [
      $self => {
        _start     => '_start',
        _stop      => '_stop',
        _child     => '_child',
        _default   => '_default',

        hello      => 'hello',
        offer      => 'offer',
        allocation => 'allocation',

        SendHello     => 'SendHello',
        StartBidding  => 'StartBidding',
        SendBid       => 'SendBid',
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

  my $strategy = $self->{Strategies}{$self->{Strategy}};
  if ( !defined($strategy) ) {
    die 'No handler for strategy ',$self->{Strategy},"\n";
  }
  $self->{StrategyHandler} = $self->can($strategy);

  $self->{MaxBids} = 5;
  if ( $self->{NBids} ) { $self->{MaxBids} = $self->{NBids}; }
  $self->{NBids} = $self->{MaxBids};

  $self->Log($self->{Me},': Start bidding!');
  POE::Kernel->yield('StartBidding');
}

sub SendHello {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];

  $self->Log('SendHello...');
  $kernel->post($self->{Auctioneer},'hello',$self->{Me},$self->{Valuation});
}

# Handlers for the interaction with the auctioneer
sub StartBidding { # re-start a game!
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  my $hash = $self->{Me};

  delete $self->{allocation};
  no strict 'refs';
  my $nkeys = scalar keys %$hash;
  map { $self->{$_} = $hash->{$_} } keys %$hash;
  $kernel->post($self->{Auctioneer},'hello',$self->{Me},$self->{Valuation});

  $self->Log('Start bidding...');
  $kernel->delay_set('SendBid',0.3);
}

sub hello {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];

  foreach ( keys %{$args} ) {
    $self->{$_} = $args->{$_};
  }
}

sub goodbye {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  $self->Log('Goodbye handler...');
}

sub offer {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  my $offer = $args->{$self->{Me}};
  $self->Log('Got offer: ',$self->allocstr($offer->{c},$offer->{a}));
  $kernel->delay_set('SendBid',0.3);
  $self->{allocation} = $args;
}

sub allocation {
  my ($self,$kernel,$args) = @_[ OBJECT, KERNEL, ARG0 ];
  my $offer = $args->{$self->{Me}};

  $self->Log('Got allocation: ',$self->allocstr($offer->{c},$offer->{a}),);
  $self->{NCycles}--;
  return unless $self->{NCycles};

  $kernel->delay_set('SendBid',0.3);
  $self->{allocation} = $args;

  $self->{NBids} = int( rand() * $self->{MaxBids} ) + 1;
  print "\n";
}

sub SendBid {
  my ($self,$kernel) = @_[ OBJECT, KERNEL ];
  my ($bid,$response,$strategy);

  if ( $self->{NBids}-- <= 0 ) {
    $self->Log("I'm happy now :-)") if $self->{NBids} == 0;
    return;
  }

  return unless $bid = $self->{StrategyHandler}->($self);
  $self->{Bid} = $bid;
  $kernel->post($self->{Auctioneer},'bid',$self->{Me},$bid);
  $self->Log('Bid: ',$self->bidstr($bid->{p},$bid->{q}),' (NBids = ',$self->{NBids},')');
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

  $theta = $k * $m * ($qbar - $m/2);
  $utility = $theta - $C;
  $self->Dbg(sprintf("(k=$k,qbar=$qbar), a=%.1f, c=%.1f, theta=%.1f, utility=%.1f",$A,$C,$theta,$utility));

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
    $self->Log("Deal with the edge case (theta'=$thetap, cmax=$cmax)");
    $qstar = $qbar;
    $pstar = 0; # TW $self->{Epsilon};
  }

# calculate the epsilon-best reply
  $qstar -= $self->{Epsilon}/($k * $qbar);
  $pstar = $k * ( $qbar - $qstar );

  $qstar = int(1000 * $qstar) / 1000;
  $pstar = int(1000 * $pstar) / 1000;
  if ( $pstar < 1 ) { $pstar = 1; } # TW

  if ( $self->{Bid} &&
       $pstar == $self->{Bid}{p} &&
       $qstar == $self->{Bid}{q} ) {
    $self->Log("Not submitting a new bid (q=$qstar,p=$pstar)");
    return;
  }

  $self->Log("Optimal bid: (q=$qstar,p=$pstar)");
  return { p => $pstar, q => $qstar };
}

sub bidstr {
  my ($self,$p,$q) = @_;
  return sprintf("(p=%.3f,q=%.3f)",$p,$q);
}
sub allocstr {
  my ($self,$c,$a) = @_;
  return sprintf("(c=%.3f,a=%.3f)",$c,$a);
}

sub StrategySpendBudget {
  my $self = shift;
  my ($budget,$target,$allocation);
  my ($delta,$q,$p,$tolerance,$eta,$qstar,$pstar);

  $target    = $self->{Valuation}{target};
  $budget    = $self->{Valuation}{budget};
  $tolerance = $self->{Valuation}{tolerance};
  $tolerance = 0.05 unless $tolerance;
  $eta       = $self->{Valuation}{eta};
  $eta       = 0.2 unless $eta;

# If my target is zero, don't bid!
  return unless $target;

# If this is my first bid, bid for everything at full price
  if ( ! $self->{allocation} ) {
    $qstar = $target;
    $pstar = $budget / $target;
    $self->Log("SpendBudget: initial bid: ",$self->bidstr($pstar,$qstar));
    return { q => $qstar, p => $pstar };
  }

  $q = $self->{allocation}{$self->{Me}}{a};
  $p = $self->{allocation}{$self->{Me}}{c};

# 1) if the price is above my budget, bid 90% of this allocation but at my budget
  if ( $q*$p > $budget ) {
    $self->Log('Price is out of my budget');
    $q *= 0.9;
    return { q => $q, p => $budget/$p };
  }

# 2) if I got more than I asked for, stay put
  if ( $q >= $target ) {
    $self->Log("Woo-hoo, jackpot! Staying put...");
    return;
  }

# 3) If I'm close to the target, take it.
  $delta = ($target - $q) / $target;
  if ( $delta < $tolerance ) { # $delta is positive, by 2)...
    $self->Log("This is close enough ($delta)");
    return;
  }

# 4) if I'm close to my last bid, settle for that, but only if the
# cost is non-zero. If the cost is zero I should up the price.
  $delta = ( $self->{Bid}{q} - $q ) / $self->{Bid}{q};
  if ( abs($delta) <= $tolerance && $p > 0 ) {
    $self->Log("I'm happy with my allocation, staying put...");
    return;
  }

# 5) if I get zero allocation, bid 1/10th of my allocation instead
  if ( !$q ) {
    $qstar = $target / 10;
    $pstar = $budget / $qstar;
    $self->Log("Got nothing! Aim low...: ",$self->bidstr($pstar,$qstar));
    return { q => $qstar, p => $pstar };
  }

# 6) try to get closer to my target by closing the gap by some
# fixed fraction of the distance between the offer and the target
# However, if this doesn't change my bid by some small amount, give up
# However (again), try anyway if my price was zero last time.
  $qstar = $q * (1-$eta) + $target * $eta;
  $pstar = $budget / $qstar;
  $delta = abs( $qstar - $q ) / $q;
  if ( $delta < $tolerance && $p ) {
    $self->Log("Seems I can't do any better :-(");
    $self->Log("pstar=$pstar, qstar=$qstar, p=$p, q=$q, delta=$delta, tolerance=$tolerance, budget=$budget");
    return;
  }

  $self->Log("SpendBudget bid: ",$self->bidstr($pstar,$qstar));
  return { q => $qstar, p => $pstar };
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