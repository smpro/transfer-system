########################################################################################################
#
# Exec rfstat command and return the output as an array
#
########################################################################################################
#
# This module has to receive as arguments:
# -PFN => The complete path of the file we want to check.
#
# Optionally:
# -retries => The number of retries we will do before giving up.
# -retry_backoff => The number of seconds we will wait before the next try.
#
#
# After finishing the rfstat command the module will return an array with the next info:
# [0]-status => It will be 0 if everything went fine or !=0 if there was something wrong.
# [1]-stats_data => It's a reference to the stats returned by rfstat command (hash of stats).
# The keys are the names of each stat and the content is the stat.
# [2]-stats_fields => It's a reference to the names of each stat(array of names).
# [3]-stats_number => It's the number of stats we have collected.
# (The length of status_data and status_field).
#
# Examples:
# First element: $stats_data->{$stats_fields->[0]}
# Last element:  $stats_data->{$stats_fields->[$stats_number - 1]}
# With the name of the field: $stats_data->{'Size (bytes)'}
#
########################################################################################################


use strict;
use warnings;
package T0::Castor::RfstatLite;
use T0::Util;

our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS, $VERSION);

use Carp;
$VERSION = 1.00;
@ISA = qw/ Exporter /;

our $hdr = __PACKAGE__ . ':: ';
sub Croak   { croak $hdr,@_; }
sub Carp    { carp  $hdr,@_; }
sub Verbose { T0::Util::Verbose( (shift)->{Verbose}, @_ ); }
sub Debug   { T0::Util::Debug(   (shift)->{Debug},   @_ ); }
sub Quiet   { T0::Util::Quiet(   (shift)->{Quiet},   @_ ); }

sub new {

  my ($class, $PFN, $retries, $retry_backoff) = @_;
  my $self = {};
  bless($self, $class);

  # Store arguments
  $self->{PFN} = $PFN;
  $self->{retries} = $retries;
  $self->{retry_backoff} = $retry_backoff;

  # Return argument
  $self->{status} = 0;
  $self->{stats_number} = 0;
  $self->{stats_fields} = undef;
  $self->{stats_data} = undef;


  # Run rfstat
  my @stats = qx {unset STAGER_TRACE ; unset RFIO_TRACE ; rfstat $self->{PFN}};
  $self->{status} = $?;

  while ( $self->{status} != 0  && ( defined($self->{retries}) && $self->{retries}>0 )) {

    $self->rfstat_failed(\@stats);

    $self->Quiet("Retrying rfstat on ", $self->{PFN}, "...\n");
    $self->{retries}--;

    # Sleep before retrying
    if ( defined($self->{retry_backoff}) ) {
      sleep( $self->{retry_backoff});
    }

    # Run rfstat
    @stats = qx {unset STAGER_TRACE ; unset RFIO_TRACE ; rfstat $self->{PFN}};
    $self->{status} = $?;
  }

  # No more retries
  if( $self->{status} != 0 ) {
    $self->rfstat_failed(\@stats);
    $self->Quiet("No more retries rfstat on ", $self->{PFN}, "...\n");
  }

  # Organize the data inside a hash
  else {
    my($index) = 0;

    foreach my $stat ( @stats ) {
      chomp($stat);
      my ($field,$data) = split (" : ",$stat);

      # Remove spaces at the end
      $field =~ s/\s+$//;

      $self->{stats_fields}->[$index++] = $field;
      $self->{stats_data}->{$field} = $data;
    }

    $self->{stats_number} = $index;
  }

  # Return the status and stats information
  return ( $self->{status}, $self->{stats_number}, $self->{stats_fields}, $self->{stats_data} );
}


# Print the results of the rfstat
sub rfstat_failed {

  my $self = shift;
  my $stats_ref = shift;
  my @stats = @$stats_ref;

  $self->Quiet("Rfstat failed, output follows\n");

  foreach my $stat ( @stats ) {
    $self->Quiet("RFSTAT: ", $stat);
  }
}


1;