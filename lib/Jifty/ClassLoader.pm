use warnings;
use strict;

package Jifty::ClassLoader;

=head1 NAME

Jifty::ClassLoader - Loads the application classes

=head1 DESCRIPTION

C<Jifty::ClassLoader> loads all of the application's model and action
classes, generating classes on the fly for Collections of pre-existing
models.

=head2 new

Returns a new ClassLoader object.  Doing this installs a hook into
C<@INC> that allows L<Jifty::ClassLoader> to dynamically create
needed classes if they do not exist already.  This works because if
use/require encounters a blessed reference in C<@INC>, it will
invoke the INC method with the name of the module it is searching
for on the reference.

Takes one mandatory argument, C<base>, which should be the the
application's base path; all of the classes under this will be
automatically loaded.

=cut

sub new {
    my $class = shift;
    my $self = bless {@_}, $class;

    push @INC, $self;
    return $self;
}

=head2 INC

The hook that is called when a module has been C<require>'d that
cannot be found on disk.  The following stub classes are
auto-generated:

=over

=item I<Application>

An empty application base class is created that doen't provide any
methods or inherit from anything.

=item I<Application>::Record

An empty class that descends from L<Jifty::Record> is created.

=item I<Application>::Event

An empty class that descends from L<Jifty::Event> is created.

=item I<Application>::Collection

An empty class that descends from L<Jifty::Collection> is created.

=item I<Application>::Notification

An empty class that descends from L<Jifty::Notification>.

=item I<Application>::Dispatcher

An empty class that descends from L<Jifty::Dispatcher>.

=item I<Application>::Handle

An empty class that descends from L<Jifty::Handle> is created.

=item I<Application>::Bootstrap

An empty class that descends from L<Jifty::Bootstrap>.

=item I<Application>::Upgrade

An empty class that descends from L<Jifty::Upgrade>.

=item I<Application>::CurrentUser

An empty class that descends from L<Jifty::CurrentUser>.

=item I<Application>::Model::I<Anything>Collection

If C<I<Application>::Model::I<Something>> is a valid model class, then
it creates a subclass of L<Jifty::Collection> whose C<record_class> is
C<I<Application>::Model::I<Something>>.

=item I<Application>::Action::(Create or Update or Delete)I<Anything>

If C<I<Application>::Model::I<Something>> is a valid model class, then
it creates a subclass of L<Jifty::Action::Record::Create>,
L<Jifty::Action::Record::Update>, or L<Jifty::Action::Record::Delete>
whose I<record_class> is C<I<Application>::Model::I<Something>>.

=back

=cut

# This subroutine's name is fully qualified, as perl will ignore a 'sub INC'
sub Jifty::ClassLoader::INC {
    my ( $self, $module ) = @_;
    my $base = $self->{base};
    return undef unless ( $module and $base );

    # Canonicalize $module to :: style rather than / and .pm style;
    $module =~ s/.pm$//;
    $module =~ s{/}{::}g;

    # The quick check
    return undef unless $module =~ m!^$base!;

    if ( $module =~ m!^(?:$base)$! ) {
        return $self->return_class(
            "use warnings; use strict; package " . $base . ";\n" . " 1;" );
    }
#    elsif ( $module =~ m!^(?:$base)::Action$! ) {
#        return $self->return_class(
#                  "use warnings; use strict; package $module;\n"
#                . "use base qw/Jifty::Action/; sub _autogenerated { 1 };\n"
#                . "1;" );
#    }
    elsif ( $module =~ m!^(?:$base)::(Record|Collection|Notification|Dispatcher|Bootstrap|Upgrade|Handle|Event|Event::Model|Action::Record::\w+)$! ) {
        return $self->return_class(
                  "use warnings; use strict; package $module;\n"
                . "use base qw/Jifty::$1/; sub _autogenerated { 1 };\n"
                . "1;" );
    } elsif ( $module =~ m!^(?:$base)::View$! ) {
        return $self->return_class(
                  "use warnings; use strict; package $module;\n"
                . "use base qw/Jifty::View::Declare::Templates/; sub _autogenerated { 1 };\n"
                . "1;" );
    } elsif ( $module =~ m!^(?:$base)::CurrentUser$! ) {
        return $self->return_class(
                  "use warnings; use strict; package $module;\n"
                . "use base qw/Jifty::CurrentUser/; sub _autogenerated { 1 };\n"
                . "1;" );
    } elsif ( $module =~ m!^(?:$base)::Model::(\w+)Collection$! ) {
        return $self->return_class(
                  "use warnings; use strict; package $module;\n"
                . "use base qw/@{[$base]}::Collection/;\n"
                . "sub record_class { '@{[$base]}::Model::$1' }\n"
                . "1;" );
    } elsif ( $module =~ m!^(?:$base)::Event::Model::([^\.]+)$! ) {
        my $modelclass = $base . "::Model::" . $1;
        Jifty::Util->require($modelclass);

        return undef unless eval { $modelclass->table };

        return $self->return_class(
                  "use warnings; use strict; package $module;\n"
                . "use base qw/${base}::Event::Model/;\n"
                . "sub record_class { '$modelclass' };\n"
                . "sub autogenerated { 1 };\n"
                . "1;" );
    } elsif ( $module =~ m!^(?:$base)::Action::(Create|Update|Delete|Search)([^\.]+)$! ) {
        my $modelclass = $base . "::Model::" . $2;

        Jifty::Util->require($modelclass);

        return undef unless eval { $modelclass->table };

        return $self->return_class(
                  "use warnings; use strict; package $module;\n"
                . "use base qw/$base\::Action::Record::$1/;\n"
                . "sub record_class { '$modelclass' };\n"
                . "sub autogenerated { 1 };\n"
                . "1;" );
    }
    return undef;
}

=head2 return_class CODE

A helper method; takes CODE as a string and returns an open filehandle
containing that CODE.

=cut

sub return_class {
    my $self = shift;
    my $content = shift;


    open my $fh, '<', \$content;
    return $fh;

}

=head2 require

Loads all of the application's Actions and Models.  It additionally
C<require>'s all Collections and Create/Update actions for each Model
base class -- which will auto-create them using the above code if they
do not exist on disk.

=cut

sub require {
    my $self = shift;
    
    my $base = $self->{base};
    # if we don't even have an application class, this trick will not work
    return unless ($base); 
    Jifty::Util->require($base);
    Jifty::Util->require($base."::CurrentUser");
    eval { 
    Jifty::Module::Pluggable->import(
        # $base goes last so we pull in the view class AFTER the model classes
        search_path => [map { $base . "::" . $_ } ('Model', 'Action', 'Notification', 'Event')],
        require => 1,
        except  => qr/\.#/,
        inner   => 0
    );
    };
    
    if ($@) {
        warn "$@";
    }
    my %models;
    $models{$_} = 1 for grep {/^($base)::Model::(.*)$/ and not /Collection$/} $self->plugins;
    $self->models(sort keys %models);
    for my $full ($self->models) {
        my($short) = $full =~ /::Model::(.*)/;
        Jifty::Util->require($full . "Collection");
        Jifty::Util->require($base . "::Action::" . $_ . $short)
            for qw/Create Update Delete Search/;
    }
}

sub require_views {
    my $self = shift;
    
    my $base = $self->{base};
    # if we don't even have an application class, this trick will not work
    return unless ($base); 
    Jifty::Util->require($base."::View");
}

=head2 models

Accessor to the list of models this application has loaded.

In scalar context, returns a mutable array reference; in list context,
return the content of the array.

=cut

sub models {
    my $self = shift;
    if (@_) {
        $self->{models} = ref($_[0]) ? $_[0] : \@_;
    }
    wantarray ? @{ $self->{models} ||= [] } : $self->{models};
}


=head1 Writing your own classes

If you require more functionality than is provided by the classes
created by ClassLoader then you should create a class with the
appropriate name and add your extra logic to it.

For example you will almost certainly want to write your own
dispatcher, so something like:

 package MyApp::Dispatcher;
 use Jifty::Dispatcher -base;

If you want to add some application specific behaviour to a model's
collection class, say for the User model, create F<UserCollection.pm>
in your applications Model directory.

 package MyApp::Model::UserCollection;
 use base 'MyApp::Collection';

=cut

1;
