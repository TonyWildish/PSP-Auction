package PSP::Session;
use strict;
use warnings;
use HTTP::Status qw / :constants / ;
use POE;
use JSON::XS;
use URI::Encode qw(uri_encode uri_decode);
use LWP::UserAgent;

# use Data::Dumper;
# $Data::Dumper::Terse=1;
# $Data::Dumper::Indent=0;

sub _child {}
sub _stop {}

sub _default {
  my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];
  my $ref = ref($self);
  die <<EOF;

  Default handler for class $ref:
  The default handler caught an unhandled "$_[ARG0]" event.
  The $_[ARG0] event was given these parameters: @{$_[ARG1]}

  (...end of dump)
EOF
}

sub _start {
  my ( $self, $kernel, $session ) = @_[ OBJECT, KERNEL, SESSION ];
  $kernel->alias_set($self->{Me});
  $self->Log("Alias set to ",$self->{Me});
  if ( $self->can('start') ) { $self->start(); }
  if ( $self->can('PostReadConfig') ) { $self->PostReadConfig(); }
  $kernel->delay_set('re_read_config',$self->{ConfigPoll});
  $kernel->state($_, $self) foreach @{$self->{HandlerNames}};

  $self->{ua} = LWP::UserAgent->new();
}

sub StopListening {
  my $self = shift;
  $self->Log("Stub: StopListening");
  $self->{Listener}->stop();
}

sub StartListening {
  my $self = shift;
  $self->Log("StartListening on port ",$self->{Port});
  $self->{Listening} = 1;
  $self->{Listener} = PSP::Listener->new (
    Port  => $self->{Port},
    Alias => $self->{Me},
  );
}

# Handlers for steering HTTP interaction
sub ContentHandler {
  my ($self,$kernel,$request, $response) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];
  my ($uri,$path,$query,$args,$substr,$key,$value,$client);
  $uri = $request->{_uri};
  $path = $uri->path();
  $query = uri_decode($uri->query());
  $self->Dbg("Got request for $path with query=", ($query ? $query : '') );

# Players send a URL with their ID in it, but the Auctioneer doesn't
  if ( $path =~ m%^/([^/]*)(/(.*))?$% ) {
    $client = $1;
    $path   = $3;
  } else {
    $self->Log("Don't understand request for $path");
    $response->code(HTTP_FORBIDDEN);
    return HTTP_FORBIDDEN;
  }
  if ( !defined($path) ) { $path = $client; undef $client; }
  if ( !defined($self->{Handlers}{$path}) ) {
    $self->Log("No handler for '$path': Forbidding...");
    $response->code(HTTP_FORBIDDEN);
    return HTTP_FORBIDDEN;
  }

  $args = decode_json($query);
  $kernel->yield($path,$args,$client);

  $response->code(HTTP_OK);
  $response->push_header("Content-Type", "text/plain");
  $response->content("\n\nThanks, I got the message:\n\n");
  return HTTP_OK;
}

sub ErrorHandler {
  my ($self,$kernel,$request, $response) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];
  return HTTP_OK if $response->{_rc} == HTTP_OK;

  my ($uri,$path,$query,$args,$substr,$key,$value);
  $uri = $request->{_uri};
  $path = $uri->path();
  $query = $uri->query();
  $self->Dbg("Handle error on request for $path with query=", ($query ? $query : '') );

  return HTTP_OK;
}

1;