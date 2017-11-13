package OmniPITR::Program;
use strict;
use warnings;
use English qw( -no_match_vars );

use OmniPITR::Log;
use OmniPITR::Pidfile;
use OmniPITR::Tools qw( run_command );
use POSIX qw( strftime );
use Getopt::Long qw( :config no_ignore_case );
use File::Basename;
use File::Path qw( mkpath rmtree );
use File::Spec;
use Pod::Usage;
use Sys::Hostname;
use Carp;

our $VERSION = '2.0.0';

=head1 new()

Object contstructor.

Since all OmniPITR programs are based on object, and they start with
doing the same things (namely reading and validating command line
arguments) - this is wrapped in here, to avoid code duplication.

Constructor also handles pid file creation, in case it was requested.

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->{ 'meta' } = {
        'started_at' => time(),
        'hostname'   => hostname(),
    };
    $self->{ 'meta' }->{ 'timezone' } = strftime( '%Z', localtime( $self->{ 'meta' }->{ 'started_at' } ) );
    $self->check_debug();
    $self->read_args();
    $self->validate_args();
    $self->{ 'pid-file' } = OmniPITR::Pidfile->new( 'pidfile' => $self->{ 'pid-file' } ) if $self->{ 'pid-file' };

    return $self;
}

=head1 check_debug()

Internal method providing --debug option handling to every omnipitr program.

If *first* argument to omnipitr program it will print to stderr all arguments, and environment variables.

=cut

sub check_debug {
    my $self = shift;
    return if 0 == scalar @ARGV;
    return unless '--debug' eq $ARGV[ 0 ];

    carp( "DEBUG INFORMATION:\n" );
    for my $key ( sort keys %ENV ) {
        carp( sprintf( "ENV: '%s' => '%s'\n", $key, $ENV{ $key } ) );
    }
    carp( "Command line arguments: [" . join( "] , [", @ARGV ) . "]\n" );
    shift @ARGV;

    return;
}

=head1 run()

Just a stub method, that has to be overriden in subclasses.

=cut

sub run {
    my $self = shift;
    croak( "run() method in OmniPITR::Program was not overridden!" );
}

=head1 verbose()

Shortcut to make code a bit nicer.

Returns values of (command line given) verbose switch.

=cut

sub verbose { return shift->{ 'verbose' }; }

=head1 log()

Shortcut to make code a bit nicer.

Returns logger object.

=cut

sub log { return shift->{ 'log' }; }

=head1 prepare_temp_directory()

Helper function, which builds path for temp directory, and creates it.

Path is generated by using given temp-dir and 'omnipitr-backup-master' named.

For example, for temp-dir '/tmp' used temp directory would be /tmp/omnipitr-backup-master.

If any arguments are passed - they are treated as subdirectories. For example, in above example, if ("xxx", "yyy") was passed, generated directory would be /tmp/omnipitr-backup-master/xxx/yyy.
=cut

sub prepare_temp_directory {
    my $self = shift;
    return if $self->{ 'temp-dir-prepared' };
    my @sub_elements = @_;
    my $full_temp_dir = File::Spec->catfile( $self->{ 'temp-dir' }, basename( $PROGRAM_NAME ), $PROCESS_ID, @sub_elements );
    mkpath( $full_temp_dir );
    $self->{ 'temp-dir' }          = $full_temp_dir;
    $self->{ 'temp-dir-prepared' } = 1;
    return;
}

=head1 temp_file()

Returns full path to temp file. Name of the file is passed as argument, temp directory is created (if needed) and full path is returned.

=cut

sub temp_file {
    my $self     = shift;
    my $filename = shift;
    $self->prepare_temp_directory;
    return File::Spec->catfile( $self->{ 'temp-dir' }, $filename );
}

=head1 DESTROY()

Destructor for object - removes temp directory on program exit.

=cut

sub DESTROY {
    my $self = shift;
    if ( $self->{ 'temp-dir-prepared' } ) {
        rmtree( [ $self->{ 'temp-dir' } ], 0 );
        delete $self->{ 'temp-dir-prepared' };
    }
    return;
}

=head1 get_list_of_all_necessary_compressions()

Scans list of destinations, and gathers list of all compressions that have to be made.

This is to be able to compress file only once even when having multiple destinations that require compressed format.

This function is used by all programs that need to compress "stuff" - L<omnipitr-archive>, L<omnipitr-backup-master> and L<omnipitr-backup-slave>.

=cut

sub get_list_of_all_necessary_compressions {
    my $self = shift;

    croak 'get_list_of_all_necessary_compressions() method called, but there are no destinations?!' unless $self->{ 'destination' };

    my %compression = ();

    for my $dst_type ( qw( local remote direct pipe ) ) {
        next unless my $dsts = $self->{ 'destination' }->{ $dst_type };
        for my $destination ( @{ $dsts } ) {
            $compression{ $destination->{ 'compression' } } = 1;
        }
    }

    $self->{ 'compressions' } = [ keys %compression ];

    return;
}

=head1 get_control_data()

Calls pg_controldata, and parses its output.

Verifies that output contains 2 critical pieces of information:

=over

=item * Latest checkpoint's REDO location

=item * Latest checkpoint's TimeLineID

=back

=cut

sub get_control_data {
    my $self         = shift;
    my $control_data = {};

    my $handle;
    if (   ( !defined $self->{ 'error-pgcontroldata' } )
        || ( 'break' eq $self->{ 'error-pgcontroldata' } ) )
    {
        $handle = sub {
            $self->log->fatal( @_ );
        };
    }
    elsif ( 'ignore' eq $self->{ 'error-pgcontroldata' } ) {
        $handle = sub {
            $self->log->error( @_ );
        };
    }
    else {
        $handle = sub {
            $self->log->error( @_ );
            sleep 600 while 1;
        };
    }

    $self->prepare_temp_directory();

    my $response = run_command( $self->{ 'temp-dir' }, $self->{ 'pgcontroldata-path' }, $self->{ 'data-dir' } );
    if ( $response->{ 'error_code' } ) {
        $handle->( 'Error while getting pg_controldata for %s: %s', $self->{ 'data-dir' }, $response );
        return;
    }

    my @lines = split( /\s*\n/, $response->{ 'stdout' } );
    for my $line ( @lines ) {
        unless ( $line =~ m{\A([^:]+):\s*(.*)\z} ) {
            $handle->( 'Pg_controldata for %s contained unparseable line: [%s]. Full response: %s', $self->{ 'data-dir' }, $line, $response );
            return;
        }
        $control_data->{ $1 } = $2;
    }

    unless ( $control_data->{ "Latest checkpoint's REDO location" } ) {
        $handle->( 'Pg_controldata for %s did not contain latest checkpoint redo location. Full response: %s', $self->{ 'data-dir' }, $response );
        return;
    }
    unless ( $control_data->{ "Latest checkpoint's TimeLineID" } ) {
        $handle->( 'Pg_controldata for %s did not contain latest checkpoint timeline ID. Full response: %s', $self->{ 'data-dir' }, $response );
        return;
    }

    return $control_data;
}

=head1 psql()

Runs given query via psql - assumes there is $self->{'psql-path'}.

Uses also:

=over

=item * username

=item * database

=item * port

=item * host

=item

optional keys from $self.

On first run it will cache psql call arguments, so if you'd change them on
subsequent calls, you have to delete $self->{'psql'}.

In case of errors, it raises fatal error.

Otherwise returns stdout of the psql.

=cut

sub psql {
    my $self  = shift;
    my $query = shift;

    unless ( $self->{ 'psql' } ) {
        my @psql = ();
        push @psql, $self->{ 'psql-path' };
        push @psql, '-qAtX';
        push @psql, ( '-U', $self->{ 'username' } ) if $self->{ 'username' };
        push @psql, ( '-d', $self->{ 'database' } ) if $self->{ 'database' };
        push @psql, ( '-h', $self->{ 'host' } )     if $self->{ 'host' };
        push @psql, ( '-p', $self->{ 'port' } )     if $self->{ 'port' };
        push @psql, '-c';
        $self->{ 'psql' } = \@psql;
    }

    $self->prepare_temp_directory();

    my @command = ( @{ $self->{ 'psql' } }, $query );

    $self->log->time_start( $query ) if $self->verbose;
    my $status = run_command( $self->{ 'temp-dir' }, @command );
    $self->log->time_finish( $query ) if $self->verbose;

    $self->log->fatal( 'Running [%s] via psql failed: %s', $query, $status ) if $status->{ 'error_code' };

    return $status->{ 'stdout' };
}

=head1 find_tablespaces()

Helper function.  Takes no arguments.  Uses pg_tblspc directory and returns
a hashref of the physical locations of tablespaces.
Keys in the hashref are tablespace OIDs (link names in pg_tblspc). Values
are hashrefs with two keys:

=over

=item * pg_visible - what is the path to tablespace that PostgreSQL sees

=item * real_path - what is the real absolute path to tablespace directory

=back

The two can be different in case tablespace got moved and symlinked back to
original location, or if tablespace path itself contains symlinks.

=cut

sub get_tablespaces {
    my $self = shift;

    # Identify any tablespaces and get those
    my $tablespace_dir = File::Spec->catfile( $self->{ 'data-dir' }, "pg_tblspc" );
    my %tablespaces;

    return unless -e $tablespace_dir;

    my @pgfiles;
    opendir( my $dh, $tablespace_dir ) or $self->log->fatal( "Unable to open tablespace directory $tablespace_dir" );

    # Push onto our list the locations that are pointed to by the pg_tblspc symlinks
    foreach my $filename ( readdir $dh ) {
        next if $filename !~ /^\d+$/;    # Filename should be all numeric
        my $full_name = File::Spec->catfile( $tablespace_dir, $filename );
        next if !-l $full_name;          # It should be a symbolic link
        my $pg_visible = readlink $full_name;
        my $real_path  = Cwd::abs_path( $full_name );
        $tablespaces{ $filename } = {
            'pg_visible' => $pg_visible,
            'real_path'  => $real_path,
        };
    }
    closedir $dh;

    return \%tablespaces;
}

=head1 read_args()

Function which does all the parsing of command line argument.

Additionally, it starts logger object (and stores it in $self->{'log'}),
because it works this way in virtually all omnipitr programs.

It should be either overloaded in subclasses, or there should be additional methods:

=over

=item * read_args_specification() - providing specification of options for given program

=item * read_args_normalization()

=back

read_args_specification is supposed to return hashref, where keys are names of options, and values are hashrefs with two optional keys:

=over

=item * default - default value.

=item * aliases - option aliases passed as arrayref

=item * optional - wheter value for given argument is optional (i.e. you can have --option, or --option "value").

=item * type - Getopt::Long based type. This can be ignored for simple boolean options, or can be something like "s", "s@", "i".

=back

read_args_normalization() is called after option parsing, and only if there
are no unknown options, there is no --version, nor --help. It is passed
single hashref, with all parsed options, and default values applied.

=cut

sub read_args {
    my $self = shift;

    my @argv_copy = @ARGV;

    my $specification = $self->read_args_specification();
    $specification->{ 'help' }    ||= { 'aliases' => [ '?' ] };
    $specification->{ 'version' } ||= { 'aliases' => [ 'V' ] };

    # This will contain values for option parsed out from command line and
    # given files.
    my $parsed_options = {};

    # This will contain parameters to pass to GetOptionsFromArray() call
    my @getopt_args = ();

    for my $key ( keys %{ $specification } ) {
        my $S         = $specification->{ $key };
        my @all_names = ( $key );
        push @all_names, @{ $S->{ 'aliases' } } if $S->{ 'aliases' };
        my $option_spec = join '|', @all_names;
        if ( $S->{ 'type' } ) {
            $option_spec .= $S->{ 'optional' } ? ':' : '=';
            $option_spec .= $S->{ 'type' };
        }

        $parsed_options->{ $key } = $S->{ 'default' };

        # Line below puts to getopt_args full option specification (like:
        # rsync-path|rp=s) and reference to value in hash with parsed
        # options that should be used to store parsed value.
        push @getopt_args, $option_spec, \( $parsed_options->{ $key } );
    }
    push @getopt_args, 'config-file|config|cfg=s', sub {
        unshift @ARGV, $self->_load_config_file( $_[ 1 ] );
    };

    my $status = GetOptions( @getopt_args );
    if ( !$status ) {
        $self->show_help_and_die();
    }

    $self->show_help_and_die() if $parsed_options->{ 'help' };

    if ( $parsed_options->{ 'version' } ) {

        # The $self->VERSION below returns value of $VERSION variable in class of $self.
        printf '%s ver. %s%s', basename( $PROGRAM_NAME ), $self->VERSION, "\n";
        exit;
    }

    my @all_keys = keys %{ $parsed_options };
    for my $key ( @all_keys ) {
        next if defined $parsed_options->{ $key };
        next if exists $specification->{ $key }->{ 'default' };
        delete $parsed_options->{ $key };
    }
    $parsed_options->{ '-arguments' } = [ @ARGV ];

    # Restore original @ARGV
    @ARGV = @argv_copy;

    croak( '--log was not provided - cannot continue.' ) unless $parsed_options->{ 'log' };
    $parsed_options->{ 'log' } =~ tr/^/%/;

    $self->{ 'log_template' } = $parsed_options->{ 'log' };

    if ( $self->{ 'log_template' } eq '-' ) {
        $self->{ 'log' } = OmniPITR::Log->new( \*STDOUT );
    }
    else {
        $self->{ 'log' } = OmniPITR::Log->new( $self->{ 'log_template' } );
    }

    delete $parsed_options->{ 'log' };

    $self->read_args_normalization( $parsed_options );

    return;
}

=head3 show_help_and_die()

Just as the name suggests - calling this method will print help for program,
and exit it with error-code (1).

If there are any arguments, they are treated as arguments to printf()
function, and are printed to STDERR.

=cut

sub show_help_and_die {
    my $self = shift;
    if ( 0 < scalar @_ ) {
        my ( $msg, @args ) = @_;
        $msg =~ s/\s*\z/\n\n/;
        printf STDERR $msg, @args;
    }
    my $doc_path = File::Spec->catfile( $FindBin::Bin, '..', 'doc', basename( $PROGRAM_NAME ) . '.pod' );
    pod2usage(
        {
            '-verbose' => 2,
            '-input'   => $doc_path,
        }
    );
    exit( 1 );
}

=head3 _load_config_file()

Loads options from config file.

File name should be passed as argument.

Format of the file is very simple - each line is treated as option with
optional value.

Examples:

    --verbose
    --host 127.0.0.1
    -h=127.0.0.1
    --host=127.0.0.1

It is important that you don't need to quote the values - value will always
be up to the end of line (trailing spaces will be removed). So if you'd
want, for example, to have dst-local set to "/mnt/badly named directory",
you'd need to quote it when setting from command line:

    omnipitr-archive --dst-local="/mnt/badly named directory"

but not in config:

    --dst-local=/mnt/badly named directory

Empty lines, and comment lines (starting with #) are ignored.

=cut

sub _load_config_file {
    my $self     = shift;
    my $filename = shift;
    my @new_args = ();
    open my $fh, '<', $filename or croak( "Cannot open $filename: $OS_ERROR\n" );
    while ( <$fh> ) {
        s/\s*\z//;
        next if '' eq $_;
        next if /\A\s*#/;
        if ( /\A\s*(-[^\s=]*)\z/ ) {

            # -v
            push @new_args, $1;
        }
        elsif ( /\A\s*(-[^\s=]*)\s*[\s=]\s*(.*)\z/ ) {

            # -x=123 or -x 123
            push @new_args, $1, $2;
        }
        else {
            croak( "Cannot parse line: $_\n" );
        }
    }
    close $fh;
    return @new_args;
}

1;

