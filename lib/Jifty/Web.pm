use warnings;
use strict;

package Jifty::Web;

=head1 NAME

Jifty::Web - Web framework for a Jifty application

=cut

use Jifty::Everything;
use CGI::Cookie;
use Apache::Session;
use base qw/Class::Accessor Jifty::Object/;

use UNIVERSAL::require;

use vars qw/$SERIAL/;

__PACKAGE__->mk_accessors(
    qw(next_page request response session temporary_current_user action_limits)
);

=head1 METHODS

=head3 new

Creates a new C<Jifty::Web> object

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->session( {} );    # we need at least an empty session
    return ($self);
}

=head3 mason

Returns a L<HTML::Mason::Request> object

=cut

sub mason {
    return HTML::Mason::Request->instance;
}

=head3 url [SCHEME]

Returns the root url of the server.  This is pulled from the
configuration file.  Optionally overrides the default (http or https)
scheme with the given C<SCHEME>.

=cut

sub url {
    my $self = shift;
    my $url  = Jifty->config->framework("Web")->{BaseURL}
        || "http://localhost";
    my $port = Jifty->config->framework("Web")->{Port} || 8888;

    $url =~ s/^\w+/shift/e if @_;

    if (   ( $url =~ /^http\b/ and $port == 80 )
        or ( $url =~ /^https\b/ and $port == 443 ) )
    {
        return $url;
    } else {
        return $url . ":" . $port;
    }
}

=head3 serial 

Returns an integer, guaranteed to be unique within the runtime of a
particular process (ie, within the lifetime of Jifty.pm).  There's no
sort of global uniqueness guarantee, but it should be good enough for
generating things like moniker names.

=cut

sub serial {
    my $class = shift;

    # We don't use a lexical for the serial number, because then it would be
    # reset on module refresh
    $SERIAL ||= 0;
    return join( ".", ++$SERIAL, $$, int( rand(999) ) );    # Start at 1.
}

=head2 SESSION MANAGEMENT

=head3 setup_session

Sets up the current C<session> object (an L<Apache::Session> tied hash).

=cut

# Create the Apache::Session object
sub setup_session {
    my $self = shift;
    my $m    = $self->mason;
    return
        if $m
        && $m->is_subrequest;    # avoid reentrancy, as suggested by masonbook
    my %session;
    my %cookies       = CGI::Cookie->fetch();
    my $cookiename    = "JIFTY_SID_" . ( $ENV{'SERVER_PORT'} || 'NOPORT' );
    my $session_class = 'Apache::Session::File';
    my $pm            = "$session_class.pm";
    $pm =~ s|::|/|g;
    require $pm;

    $Storable::Deparse = 1;
    $Storable::Eval    = 1;

    eval {
        tie %session, $session_class,
            (
            $cookies{$cookiename} ? $cookies{$cookiename}->value() : undef ),
            {
            Directory     => '/tmp',
            LockDirectory => '/tmp'
            };
    };

    if ($@) {

        # If the session is invalid, create a new session.
        if ( $@ =~ /Object does not/i ) {
            tie %session, $session_class, undef,
                {
                Directory     => '/tmp',
                LockDirectory => '/tmp'
                };
            undef $cookies{$cookiename};
        } else {
            $self->log->fatal( "Couldn't store your session:\n", $@ );
            return;
        }
    }

    $self->session( \%session );

    return ();
}

=head3 session

Returns the current session's hash. In a regular user environment, it
persists, but a request can stop that by handing it a regular hash to
use.

=head3 save_session

If you're modifying something not at the top level of the session hash,
L<Apache::Session> won't notice and won't save your changes.  Thus, you should
call this method after you make any change to something nested inside the
session.

=cut

sub save_session {
    my $self = shift;
    $self->session->{'i'}++;
}

=head3 session_expires [DURATION]

Gets or sets how long the session cookie lasts.  C<DURATION> should be
a relative offset like C<+3M> for "3 months" or C<+3y> for "3 years".
Defaults to undefined, meaning that the session will expire when the
browser is closed.

=cut

sub session_expires {
    my $self = shift;
    $self->session->{'_expires'} = shift if @_;
    return $self->session->{'_expires'};
}

=head3 set_cookie

Sets the session cookie

=cut

sub set_cookie {
    my $self       = shift;
    my $m          = $self->mason;
    my %cookies    = CGI::Cookie->fetch();
    my $cookiename = "JIFTY_SID_" . ( $ENV{'SERVER_PORT'} || 'NOPORT' );
    my $session    = $self->session;
    if (   ( !$cookies{$cookiename} )
        or ( $session->{_expires} xor $cookies{$cookiename}->expires ) )
    {
        my $cookie = new CGI::Cookie(
            -name    => $cookiename,
            -value   => $session->{_session_id},
            -expires => $session->{_expires},
        );

        # XXX TODO might need to change under mod_perl
        $m->cgi_request->headers_out->{'Set-Cookie'} = $cookie->as_string
            if ($m);
    }
}

=head2 CURRENT USER

=head3 current_user [USER]

Getter/setter for the current user; this gets or sets the 'user' key
in the session.  These are L<Jifty::Record> objects.

If a temporary_current_user has been set, will return that instead.

If the current application has no loaded current user, we get an empty
Jifty::CurrentUser object

XXX TODO: This should be app-overridable

=cut

sub current_user {
    my $self = shift;
    $self->session->{'user'} = shift if (@_);
    return $self->temporary_current_user
        || $self->session->{'user'}
        || Jifty::CurrentUser->new();
}

=head3 temporary_current_user [USER]

Sets the current request's current_user to USER if set.

This value will _not_ be persisted to the session at the end of the
request.  To restore the original value, set temporary_current_user to
undef.

=cut

=head2 REQUEST

=head3 handle_request

This method sets up a current session, prepares a Jifty::Request
object and loads page-specific actions.

Each action is vetted in three ways -- first, it must be marked as
C<active> by the L<Jifty::Request> (this is the default).  Second, it
must be in the set of allowed classes of actions (see L</is_allowed>,
below).  Finally, the action must validate.  If it passes all of these
criteria, the action is fit to be run.

Before they are run, however, the request has a chance to be
interrupted and saved away into a continuation, to be resumed at some
later point.  This is handled by L</save_continuation>.

If the continuation isn't being saved, then C<handle_request> goes on
to run all of the actions.  If all of the actions are successful, it
looks to see if the request wished to call any continuations, possibly
jumping back and re-running a request that was interrupted in the
past.  This is handled by L</call_continuation>.

For more details about continuations, see L<Jifty::Continuation>.

=cut

sub handle_request {
    my $self = shift;

    $self->log->debug( "Handling " . $ENV{'REQUEST_URI'} );
    $self->setup_session;
    $self->response( Jifty::Response->new ) unless $self->response;
    $self->_internal_request( Jifty::Request->new->from_mason_args );
}

# Called when continuations get run, as well as by handle_request;
# takes a Jifty::Request
sub _internal_request {
    my $self = shift;
    my ($request) = @_;

    $self->request($request);
    $self->setup_page_actions;

    my @valid_actions;
    for my $request_action ( $self->request->actions ) {
        next unless $request_action->active;
        unless ( $self->is_allowed( $request_action->class ) ) {
            $self->log->warn( "Attempt to call denied action '"
                    . $request_action->class
                    . "'" );
            next;
        }

        my $action = $self->new_action_from_request($request_action);
        next unless $action;
        $self->response->result( $action->moniker => $action->result );

        eval { push @valid_actions, $action if $action->validate; };
        if ( my $err = $@ ) {
            $self->log->fatal($err);
        }
    }

    $self->save_continuation;

    unless ( $self->request->just_validating ) {
        for my $action (@valid_actions) {
            eval { $action->run; };

            if ( my $err = $@ ) {
                $self->log->fatal($err);
            }
        }
    }

    $self->set_cookie;

    $self->request->call_continuation
        if $self->response->success;

    $self->redirect if $self->redirect_required;
}

=head3 setup_page_actions

Probe the page the current user has requested to see if it has any
special actions it wants to run, if it wants to massage the existing
actions, etc.

=cut

sub setup_page_actions {
    my $self = shift;
    if ( $self->mason->base_comp->method_exists('setup_actions') ) {
        $self->mason->base_comp->call_method('setup_actions');
    }
}

=head3 request [VALUE]

Gets or sets the current L<Jifty::Request> object.

=head3 response [VALUE]

Gets or sets the current L<Jifty::Response> object.

=head2 ACTIONS

=head3 actions 

Gets the actions that have been created with this framework with
C<new_action> (whether automatically via a L<Jifty::Request>, or in
Mason code), as L<Jifty::Action> objects. (These are actually stored
in the mason notes, so that they are magically saved over redirects.)

=cut

sub actions {
    my $self = shift;

    $self->{'actions'} ||= {};
    return
        sort { ( $a->order || 0 ) <=> ( $b->order || 0 ) }
        values %{ $self->{'actions'} };
}

sub _add_action {
    my $self   = shift;
    my $action = shift;

    $self->{'actions'}{ $action->moniker } = $action;
}

=head3 allow_actions RESTRICTIONS

Takes a list of strings or regular expressions, and adds them in order
to the list of limits for the purposes of L</is_allowed>.  See
L</restrict_actions> for the details of how limits are processed.

=cut

sub allow_actions {
    my $self = shift;
    $self->restrict_actions( allow => @_ );
}

=head3 deny_actions RESTRICTIONS

Takes a list of strings or regular expressions, and adds them in order
to the list of limits for the purposes of L</is_allowed>.  See
L</restrict_actions> for the details of how limits are processed.

=cut

sub deny_actions {
    my $self = shift;
    $self->restrict_actions( deny => @_ );
}

=head3 restrict_actions POLARITY RESTRICTIONS

Method that L</allow_actions> and and L</deny_actions> call
internally; I<POLARITY> is either C<allow> or C<deny>.  Allow and deny
limits are evaluated in the order they're called.  The last limit that
applies will be the one which takes effect.  Regexes are matched
against the class; strings are fully qualified with the application's
I<ActionBasePath> (if they not already) and used as an exact match
against the class name.

If you call:

    Jifty->web->allow_actions ( qr'.*' );
    Jifty->web->deny_actions  ( qr'Foo' );
    Jifty->web->allow_actions ( qr'FooBar' );
    Jifty->web->deny_actions ( qr'FooBarDeleteTheWorld' );


calls to MyApp::Action::Baz will succeed.
calls to MyApp::Action::Foo will fail.
calls to MyApp::Action::FooBar will pass.
calls to MyApp::Action::TrueFoo will fail.
calls to MyApp::Action::TrueFooBar will pass.
calls to MyApp::Action::TrueFooBarDeleteTheWorld will fail.
calls to MyApp::Action::FooBarDeleteTheWorld will fail.

=cut

sub restrict_actions {
    my $self         = shift;
    my $polarity     = shift;
    my @restrictions = @_;

    die "Polarity must be 'allow' or 'deny'"
        unless $polarity eq "allow"
        or $polarity     eq "deny";

    $self->action_limits( [] ) unless $self->action_limits;

    for my $restriction (@restrictions) {

        # Fully qualify it if it's a string and not already so
        my $base_path = Jifty->config->framework('ActionBasePath');
        $restriction = $base_path . "::" . $restriction
            unless ref $restriction
            or $restriction =~ /^\Q$base_path\E/;

        # Add to list of restrictions
        push @{ $self->action_limits },
            { $polarity => 1, restriction => $restriction };
    }
}

=head3 is_allowed CLASS

Returns false if the I<CLASS> name (which is fully qualified with the
application's ActionBasePath if it is not already) is allowed to be
executed.  See L</restrict_actions> above for the rules that the class
name must pass.

=cut

sub is_allowed {
    my $self  = shift;
    my $class = shift;

    my $base_path = Jifty->config->framework('ActionBasePath');
    $class = $base_path . "::" . $class
        unless $class =~ /^\Q$base_path\E/;

    # Assume that it passes
    my $allow = 1;

    $self->action_limits( [] ) unless $self->action_limits;

    for my $limit ( @{ $self->action_limits } ) {

        # For each limit
        if ( ( ref $limit->{restriction} and $class =~ $limit->{restriction} )
            or ( $class eq $limit->{restriction} ) )
        {

            # If the restriction passes, set the current allow/deny
            # bit according to if this was a positive or negative
            # limit
            $allow = $limit->{allow} ? 1 : 0;
        }
    }
    return $allow;
}

=head3 form

Returns the current L<Jifty::Web::Form> object, creating one if there
isn't one already.

=cut

sub form {
    my $self = shift;

    $self->{form} ||= Jifty::Web::Form->new;
    return $self->{form};
}

=head3 new_action class => CLASS, moniker => MONIKER, order => ORDER, arguments => PARAMHASH

Creates a new action (an instance of a subclass of L<Jifty::Action>)

C<CLASS> is appended to the C<ActionBasePath> found in the
configuration file, and an instance of that class is created, passing
the C<Jifty::Web> object, the C<MONIKER>, and any other arguments that
C<new_action> was supplied.

C<MONIKER> is a unique designator of an action on a page.  The moniker
is content-free and non-fattening, and may be auto-generated.  It is
used to tie together argumentss that relate to the same action.

C<ORDER> defines the order in which the action is run, with lower
numerical values running first.

C<ARGUMENTS> are passed to the L<Jifty::Action/new> method.  In
addition, if the current request (C<$self->request>) contains an
action with a matching moniker, any arguments thare are in that
requested action but not in the C<PARAMHASH> list are set.  This
implements "sticky fields".

=cut

sub new_action {
    my $self = shift;

    my %args = (
        class     => undef,
        moniker   => undef,
        arguments => {},
        @_
    );

    my %arguments = %{ $args{arguments} };

    if ( $args{'moniker'} ) {
        my $action_in_request = $self->request->action( $args{moniker} );

    # Fields explicitly passed to new_action take precedence over those passed
    # from the request; we read from the request to implement "sticky fields".
    #
        if ( $action_in_request and $action_in_request->arguments ) {
            %arguments = ( %{ $action_in_request->arguments }, %arguments );
        }
    }

    # "Untaint" -- the implementation class is provided by the client!)
    # Allows anything that a normal package name allows
    my $class = delete $args{class};
    unless ( $class =~ /^([0-9a-zA-Z_:]+)$/ ) {
        $self->log->error( "Bad action implementation class name: ", $class );
        return;
    }
    $class = $1;    # 'untaint'

    # Prepend the base path (probably "App::Action") unless it's there already
    my $base_path = Jifty->config->framework('ActionBasePath');
    $class = $base_path . "::" . $class
        unless $class =~ /^\Q$base_path\E::/
        or $class     =~ /^Jifty::Action::/;

    unless ( $class->require ) {

# The implementation class is provided by the client, so this isn't a "shouldn't happen"
        $self->log->error( "Error requiring $class: ",
            $UNIVERSAL::require::ERROR );
        return;
    }

    my $action;

    # XXX TODO bullet proof
    eval { $action = $class->new( %args, arguments => {%arguments} ); };
    if ($@) {
        my $err = $@;
        $self->log->fatal($err);
        return;
    }

    $self->_add_action($action);

    return $action;
}

=head3 new_action_from_request REQUESTACTION

Given a L<Jifty::Request::Action>, creates a new action using C<new_action>.

=cut

sub new_action_from_request {
    my $self       = shift;
    my $req_action = shift;
    $self->new_action(
        class     => $req_action->class,
        moniker   => $req_action->moniker,
        order     => $req_action->order,
        arguments => $req_action->arguments || {}
    );
}

=head2 REDIRECTS AND CONTINUATIONS

=head3 next_page [VALUE]

Gets or sets the next page for the framework to show.  This is
normally set during the C<take_action> method or a L<Jifty::Action>

=head3 redirect_required

Returns true if we need to redirect, now that we've processed all the
actions.  The current logic just looks to see if a different
L</next_page> has been set. We probably want to make it possible to
force a redirect, even if we're redirecting back to the current page

=cut

sub redirect_required {
    my $self = shift;

    if ($self->next_page
        and ( ( $self->next_page ne $self->mason->request_comp->path )
            or $self->request->state_variables )
        )
    {
        return (1);

    } else {
        return undef;
    }
}

=head3 redirect [URL]

Redirect to the next page. If you pass this method a parameter, it
redirects to that URL rather than B<next_page>.

It creates a continuation of where you want to be, and then calls it.

=cut

sub redirect {
    my $self = shift;
    my $page = shift || $self->next_page;

    if (   $self->response->results
        or $self->request->state_variables
        or %{ $self->mason->notes } )
    {
        my $request = Jifty::Request->new();
        $request->path($page);
        $request->from_webform( map { "J:V-" . $_->key => $_->value }
                $self->request->state_variables );
        my $cont = Jifty::Continuation->new(
            request  => $request,
            response => $self->response,
            notes    => $self->mason->notes,
            parent   => $self->request->continuation,
        );
        $self->mason->redirect( $page . "?J:CALL=" . $cont->id );
    } else {
        $self->mason->redirect($page);
    }

}

=head3 save_continuation

Saves the current request and response if we've been asked to.  If we
save the continuation, we redirect to the next page -- the call to
C<save_continuation> never returns.

=cut

sub save_continuation {
    my $self = shift;

    my %args = %{ $self->request->arguments };
    if ( $args{'J:CLONE'} or grep {/^J:C-/} keys %args ) {

        # Saving a continuation
        my $c = Jifty::Continuation->new(
            request  => $self->request,
            response => $self->response,
            notes    => $self->mason->notes,
            parent   => $self->request->continuation,
            clone    => $args{'J:CLONE'},
        );
        for my $key ( keys %args ) {
            if ( $key =~ /^J:C-(.*)/ ) {
                $c->return_location( $1 => $args{$key} );
                delete $self->request->arguments->{$key};
            }
        }

# XXX Only if we're cloning should we do the following check, I think??  Cloning isn't a stack push, so it works out
        if (    delete $self->request->arguments->{'J:CLONE'}
            and $self->request->just_validating
            and $self->response->failure )
        {

# We don't get to redirect to the new page; redirect to the same page, new cont
            Jifty->web->mason->redirect(
                $self->request->path . "?J:C=" . $c->id );
        } else {

            # Set us up with the new continuation
            Jifty->web->mason->redirect( $args{'J:PATH'}
                    . ( $args{'J:PATH'} =~ /\?/ ? "&" : "?" ) . "J:C="
                    . $c->id );
        }

    }
}

=head3 multipage START_URL, ARGUMENTS

Create a multipage action.  The first argument is the URL of the start
of the multipage action -- the user will be redirected there if they
try to enter the multipage action on any other page.  The rest of the
arguments are passed to L<Jifty::Request/add_action> to create the
multipage action.

XXX This is very much not finalized

=cut

sub multipage {
    my $self = shift;
    my ( $start, %args ) = @_;

    my $request_action = Jifty->web->caller->action( $args{moniker} );

    unless ($request_action) {
        my $request = Jifty::Request->new();
        $request->merge_param(
            'J:CALL' => Jifty->web->request->continuation->id )
            if Jifty->web->request->continuation;
        $request->path("/");
        $request->add_action(%args);
        my $cont = Jifty::Continuation->new( request => $request );
        Jifty->web->redirect( $start . "?J:C=" . $cont->id );
    }

    my $action = Jifty->web->new_action_from_request($request_action);
    $action->result(
        Jifty->web->request->continuation->response->result( $args{moniker} )
        )
        if Jifty->web->request->continuation->response;
    return $action;
}

=head3 caller

Returns the L<Jifty::Request> of our enclosing continuation, or an
empty L<Jifty::Request> if we are not in a continuation.

=cut

sub caller {
    my $self = shift;

    return Jifty::Request->new unless $self->request->continuation;
    return $self->request->continuation->request;
}

=head2 HTML GENERATION

=head3 tangent PARAMHASH

If called in non-void context, creates and renders a
L<Jifty::Web::Form::Clickable> with the given I<PARAMHASH>, forcing a
continuation save.

In void context, does a redirect to the URL that the
L<Jifty::Web::Form::Clickable> object generates.

Both of these versions preserve all state variables by default.

=cut

sub tangent {
    my $self = shift;

    my $clickable = Jifty::Web::Form::Clickable->new(
        return_values  => { "" => "" },
        preserve_state => 1,
        @_
    );
    if ( defined wantarray ) {
        return $clickable->generate->render;
    } else {
        $clickable->state_variable( $_ => $self->{'state_variables'}{$_} )
            for keys %{ $self->{'state_variables'} };
        Jifty->web->mason->redirect( $clickable->complete_url );
    }
}

=head3 goto PARAMHASH

Does an instant redirect to the url generated by the
L<Jifty::Web::Form::Clickable> object generated by the I<PARAMHASH>.

=cut

sub goto {
    my $self = shift;
    Jifty->web->redirect(
        Jifty::Web::Form::Clickable->new(@_)->complete_url );
}

=head3 link PARAMHASH

Generates and renders a L<Jifty::Web::Form::Clickable> using the given
I<PARAMHASH>.

=cut

sub link {
    my $self = shift;
    return Jifty::Web::Form::Clickable->new(@_)->generate->render;
}

=head3 return PARAMHASH

Generates and renders a L<Jifty::Web::Form::Clickable> using the given
I<PARAMHASH>, additionally defaults to calling the current
continuation.

=cut

sub return {
    my $self = shift;

    $self->link( call => Jifty->web->request->continuation, @_ );
}

=head3 render_messages

Outputs any messages that have been added, in a <div id="messages">
tag.  Messages are added by calling C<message> on a L<Jifty::Result>.

=cut

# XXX TODO factor out error and message rendering as separate

sub render_messages {
    my $self = shift;

    my %results = $self->response->results;

    return '' unless %results;

    for my $type (qw(error message)) {
        next unless grep { $results{$_}->$type() } keys %results;

        my $plural = $type . "s";
        $self->mason->out(qq{<div id="$plural">});
        foreach my $moniker ( keys %results ) {
            if ( $results{$moniker}->$type() ) {
                $self->mason->out(qq{<div class="$type $moniker">});
                $self->mason->out( $results{$moniker}->$type() );
                $self->mason->out(qq{</div>});
            }
        }
        $self->mason->out(qq{</div>});
    }
    return '';
}

=head3 render_request_debug_info

Outputs the request arguments and any Mason notes in a <div
id="debug"> tag.

=cut

sub render_request_debug_info {
    my $self = shift;
    my $m    = $self->mason;
    use YAML;
    $m->out('<div class="debug">');
    $m->out('<hr /><h1>Request args</h1><pre>');
    $m->out( YAML::Dump( { $m->request_args } ) );
    $m->out('</pre>');
    $m->out('<hr /><h1>$m->notes</h1><pre>');
    $m->out( YAML::Dump( $m->notes ) );
    $m->out('</pre></div>');

    return '';
}

=head3 query_string KEY => VALUE [, KEY => VALUE [, ...]]

Returns an URL-encoded query string piece representing the arguments
passed to it.

=cut

sub query_string {
    my $self = shift;
    my %args = @_;
    my @params;
    while ( ( my $key, my $value ) = each %args ) {
        push @params,
            $key . "=" . $self->mason->interp->apply_escapes( $value, 'u' );
    }
    return ( join( ';', @params ) );
}

=head3 query_string_from_current KEY => VALUE [, KEY => VALUE [, ...]]

Returns an URL-encoded query string piece representing the arguments
passed to it; any parameter to the current request that is not
specified here is also included with the current value.

Note that L<Jifty::Action> parameters are skipped to avoid actions
taking place that shouldn't.

=cut

sub query_string_from_current {
    my $self = shift;
    my %args = ( $self->mason->request_args, @_ );
    for ( keys %args ) {
        delete $args{$_} if /^Jifty::Action-/;
    }
    return $self->query_string(%args);
}

=head3 navigation

Returns the L<Jifty::Web::Menu> for this web request; one is
automatically created if it hasn't been already.

=cut

sub navigation {
    my $self = shift;
    if (!$self->{navigation}) {
        $self->{navigation} = Jifty::Web::Menu->new();
    if (Jifty->config->framework('AdminMode')) {
            $self->{navigation}->child(AdminMode       => url => "/__jifty/admin/", label => "Administration", sort_order => 999);
        }
    }
    return $self->{navigation};
}

=head2 STATE VARIABLES

=head3 get_variable NAME

Gets a page specific variable from the request object.

Hm. should these methods be on the request and response objects?

=cut

sub get_variable {
    my $self = shift;
    my $name = shift;
    my $var  = $self->request->state_variable($name);
    return undef unless ($var);
    return $var->value();

}

=head3 set_variable NAME VALUE

Takes a key-value pair for variables to serialize and hand off to the next page.

Behind the scenes, these variables get serialized into:

* Forms on the current page (using embedded parameters)
* Redirects, by adding the parameters to the URL

In the future, they might also get stuck into:
* URLs generated by our link generation method

=cut

sub set_variable {
    my $self  = shift;
    my $name  = shift;
    my $value = shift;

    $self->{'state_variables'}->{$name} = $value;

}

=head3 state_variables

Returns all of the state variables that have been set for the next
request, as a hash; they have already been prefixed with C<J:V->

=cut

# FIXME: it seems wrong to have an accessor that exposes the
# representation, so to speak
sub state_variables {
    my $self = shift;
    my %vars;
    $vars{ "J:V-" . $_ } = $self->{'state_variables'}->{$_}
        for keys %{ $self->{'state_variables'} };

    return %vars;
}

=head2 REGIONS

=head3 get_region [QUALIFIED NAME]

Given a fully C<QUALIFIED NAME> of a region, returns the
L<Jifty::Web::PageRegion> with that name, or undef if no such region
exists.

=cut

sub get_region {
    my $self = shift;
    my ($name) = @_;
    return $self->{'regions'}{$name};
}

=head3 region PARAMHASH, 

Creates and renders a L<Jifty::Web::PageRegion>; the C<PARAMHASH> is
passed directly to its L<Jifty::Web::PageRegion/new> method.  The
region is then added to the stack of regions, and the fragment is
rendered.

=cut

sub region {
    my $self = shift;

    # Add ourselves to the region stack
    my $region = Jifty::Web::PageRegion->new(@_) or return;
    local $self->{'region_stack'}
        = [ @{ $self->{'region_stack'} || [] }, $region ];
    $region->enter;

    # Keep track of the fully qualified name (which should be unique)
    warn "Repeated region: " . $self->qualified_region
        if $self->{'regions'}{ $self->qualified_region };
    $self->{'regions'}{ $self->qualified_region } = $region;

    # Render it
    $self->mason->out( $region->render );

    "";
}

=head3 current_region

Returns the name of the current L<Jifty::Web::PageRegion>, or undef if
there is none.

=cut

sub current_region {
    my $self = shift;
    return $self->{'region_stack'}
        ? $self->{'region_stack'}[-1]->name
        : undef;
}

=head3 qualified_region

Returns the fully qualified name of the current
L<Jifty::Web::PageRegion>, or the empty string if there is none..

=cut

sub qualified_region {
    my $self = shift;
    return join( "-", map { $_->name } @{ $self->{'region_stack'} || [] } );
}

1;
