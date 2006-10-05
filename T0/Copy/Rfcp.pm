use strict;
use warnings;
package T0::Copy::Rfcp;
use POE qw( Wheel::Run Filter::Line );

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

sub new
{
  my ($class, $hash_ref) = @_;
  my $self = {};
  bless($self, $class);

  POE::Session->create(
		       inline_states => {
					 _start => \&start_tasks,
					 start_wheel => \&start_wheel,
					 monitor_task => \&monitor_task,
					 cleanup_task => \&cleanup_task,
					 got_task_stdout => \&got_task_stdout,
					 got_task_stderr => \&got_task_stderr,
					 got_task_close	=> \&got_task_close,
					 got_sigchld => \&got_sigchld,
					},
		       args => [ $hash_ref, $self ],
		      );

  return $self;
}

sub start_tasks {
  my ( $kernel, $heap, $hash_ref, $self ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

  # remember hash reference
  $heap->{inputhash} = $hash_ref;

  # remember refercne to myself
  $heap->{Self} = $self;

  # remember SvcClass
  $heap->{svcclass} = $hash_ref->{svcclass};

  # put callback session and method on heap
  $heap->{session} = $hash_ref->{session};
  $heap->{callback} = $hash_ref->{callback};

  # keep count on outstanding rfcp wheels
  $heap->{wheel_count} = 0;

  # before spawning wheels, register signal handler
  $kernel->sig( CHLD => "got_sigchld" );

  # spawn wheels
  foreach my $file ( @{ $hash_ref->{files} } )
    {
      # hash to be passed to wheel
      my %filehash = (
		      original => $file,
		      source => $file->{source},
		      target => $file->{target},
		     );

      # configure number of retries
      my $retries = undef;
      if ( exists $file->{retries} )
	{
	  $retries = $file->{retries};
	}
      elsif ( exists $hash_ref->{retries} )
	{
	  $retries = $hash_ref->{retries};
	}
      else # set to zero, makes the followup code a little easier
	{
	  $retries = 0;
	}

      $filehash{retries} = $retries;

      # configure retry delay
      my $retry_backoff = undef;
      if ( exists $file->{rety_backoff} )
	{
	  $retry_backoff = $file->{retry_backoff};
	}
      elsif ( exists $hash_ref->{retry_backoff} )
	{
	  $retry_backoff = $hash_ref->{retry_backoff};
	}
      if ( defined $retry_backoff )
	{
	  $filehash{retry_backoff} = $retry_backoff;
	}

      # configure timeout;
      my $timeout = undef;
      if ( exists $file->{timeout} )
	{
	  $timeout = $file->{timeout}
	}
      elsif ( exists $hash_ref->{timeout} )
	{
	  $timeout = $hash_ref->{timeout}
	}
      if ( defined $timeout )
	{
	  $filehash{timeout} = $timeout;
	}

      $heap->{wheel_count}++;
      $kernel->yield('start_wheel',(\%filehash));
    }
}

sub start_wheel {
  my ( $kernel, $heap, $file ) = @_[ KERNEL, HEAP, ARG0 ];

  $ENV{STAGE_SVCCLASS} = $heap->{svcclass} if ( defined $heap->{svcclass} );

  my $task = POE::Wheel::Run->new(
				  Program => [ "rfcp", $file->{source} , $file->{target} ],
				  StdoutFilter => POE::Filter::Line->new(),
				  StdoutEvent  => "got_task_stdout",
				  StderrEvent  => "got_task_stderr",
				  CloseEvent   => "got_task_close",
				 );

  $heap->{task}->{ $task->ID } = $task;
  $heap->{file}->{ $task->ID } = $file;

  $heap->{pid}->{ $task->PID } = $task->ID;

  # spawn monitoring thread
  if ( exists $file->{timeout} )
    {
      $kernel->delay_set('monitor_task',$file->{timeout},($task->ID,0));
    }
}

sub monitor_task {
  my ( $kernel, $heap, $task_id, $force_kill ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

  if ( exists $heap->{task}->{ $task_id } )
    {
      if ( $force_kill == 0 )
	{
#	  print "Task $task_id still active, kill it\n";

	  $heap->{task}->{ $task_id }->kill();

	  # 10 seconds should be enough for task to exit
	  $kernel->delay_set('monitor_task',10,($task_id,1));
	}
      else
	{
#	  print "Task $task_id still active, kill it by force\n";

	  $heap->{task}->{ $task_id }->kill(9);

	  # cleanup task if it doesn't exit after another 10 seconds
	  $kernel->delay_set('cleanup_task',10,($task_id,-1));
	}
    }
}

sub got_task_stdout {
  my ( $kernel, $heap, $stdout, $task_id ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];
#  print "RFCP STDOUT: $stdout\n";
}

sub got_task_stderr {
  my ( $stderr, $task_id ) = @_[ ARG0, ARG1 ];
  print "RFCP STDERR: $stderr\n";
}

sub got_task_close {
  my ( $kernel, $heap, $task_id ) = @_[ KERNEL, HEAP, ARG0 ];
}

sub got_sigchld {
  my ( $kernel, $heap, $child_pid, $status ) = @_[ KERNEL, HEAP, ARG1, ARG2 ];

  if ( exists $heap->{pid}->{$child_pid} )
    {
      my $task_id = $heap->{pid}->{$child_pid};

      if ( exists $heap->{task}->{ $task_id } )
	{
	  $kernel->yield('cleanup_task',($task_id,$status));
	}
    }

  return 0;
}

sub cleanup_task {
  my ( $kernel, $heap, $task_id, $status ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

  if ( exists $heap->{task}->{ $task_id } )
    {
      my $file = $heap->{file}->{$task_id};

      delete $heap->{task}->{$task_id};
      delete $heap->{file}->{$task_id};

      $heap->{wheel_count}--;

      # update status in caller hash
      $file->{original}->{status} = $status;

      if ( $status != 0 )
	{
	  $heap->{Self}->Debug("Rfcp of $file failed with status $status\n");

	  if ( $heap->{retries} > 0 )
	    {
	      $heap->{Self}->Debug("Retry count at " . $heap->{retries} . " , retrying\n");

	      $file->{retries}--;

	      if ( exists $file->{retry_backoff} )
		{
		  $heap->{wheel_count}++;
		  $kernel->delay_set('start_wheel',$file->{retry_backoff},($file));
		}
	      else
		{
		  $heap->{wheel_count}++;
		  $kernel->yield('start_wheel',($file));
		}
	    }
	  else
	    {
	      $heap->{Self}->Debug("Retry count at " . $heap->{retries} . " , abandoning\n");
	    }
	}

      if ( $heap->{wheel_count} == 0 )
	{
	  $kernel->post( $heap->{session}, $heap->{callback}, $heap->{inputhash} );
	}
    }
}

1;
