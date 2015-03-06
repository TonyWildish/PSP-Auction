#!/usr/bin/env perl -w
use strict;
use Getopt::Long qw / :config pass_through/;
use Data::Dumper;
use PSP::Util;
use PSP::Auctioneer;

my (%args);

GetOptions(
    "help"      => \$args{help},
    "verbose"   => \$args{verbose},
    "debug"     => \$args{debug},
    "test"      => \$args{test}  ,
    "config=s"  => \$args{config},
    "log=s"     => \$args{log},
    );

sub usage {
  die <<EOF;

  Usage:  {options}

where

  options are:
  --help, --verbose, --debug are all obvious
  --config <string>   specifies a config file
  --log <string>      specifies a logfile

EOF
}
$args{help} && usage();

my $auctioneer = new PSP::Auctioneer( %args, @ARGV );
if ( $args{test} ) {
  $auctioneer->test();
  exit 0;
}

POE::Kernel->run();
print "All done, outta here...\n";