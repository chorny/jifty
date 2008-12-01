package Jifty::View::Declare::BaseClass;

use strict;
use warnings;
use base qw/Exporter Jifty::View::Declare::Helpers/;

use Jifty::View::Declare::Helpers;


our @EXPORT = ( @Jifty::View::Declare::Helpers::EXPORT);

=head1 NAME

Jifty::View::Declare::BaseClass - Base class for Template::Declare views

=head1 DESCRIPTION

This class provides a base class for your L<Template::Declare> derived view classes.

=head1 METHODS

=head2 use_mason_wrapper

Call this function in your view class to use your mason wrapper for L<Template::Declare> templates,
something like:

    package TestApp::View;
    use Jifty::View::Declare -base;
    __PACKAGE__->use_mason_wrapper;

If you don't use mason then you can define a C<wrapper> function in the view class to override
default page layouts.

=cut

sub use_mason_wrapper {
    my $class = shift;
    no strict 'refs';
    no warnings 'redefine';
    *{ $class . '::wrapper' } = sub {
        my $code = shift;
        my $args = shift || {};
        # so in td handler, we made jifty::web->out appends to td
        # buffer, we need it back for here before we call $code.
        # someday we need to finish fixing the output system that is
        # in Jifty::View.
        my $td_out = \&Jifty::Web::out;
        local *Jifty::Web::out = sub { shift->mason->out(@_) };

        local *HTML::Mason::Request::content = sub {
            local *Jifty::Web::out = $td_out;
            $code->();
            my $content = Template::Declare->buffer->data;
            Template::Declare->buffer->clear;
            $content;
        };

        Jifty->handler->fallback_view_handler->show('/_elements/wrapper', $args);
    }
}

use Attribute::Handlers;
our (%Static, %Action);

=head2 Static

This function allows a developer to mark a Template::Declare template as static (unchanging), so that the compiled version can be cached on the client side and inserted with javascript

=cut

sub Static :ATTR(CODE,BEGIN) { $Static{$_[2]}++; }

=head2 Action

This function allows a developer to mark a Template::Declare template as an action. clkao owes documentation as to the meaning of this and when it would be acceptable to use it.

=cut


sub Action :ATTR(CODE,BEGIN) { $Action{$_[2]}++; }

=head2 show templatename arguments

Render a C<Template::Declare> template.

=head1 ATTRIBUTES

=head2 Static

TODO Document this...

This is part of the client-caching system being developed for Perl to allow you to translate templates into JavaScript running on the client.

=head2 Action

TODO Document this...

This is part of the client-caching system being developed for Perl to allow you to translate templates into JavaScript running on the client.

=head1 SEE ALSO

L<Template::Declare>, L<Jifty::View::Declare::Helpers>, L<Jifty::View::Declare>

=head1 LICENSE

Jifty is Copyright 2005-2007 Best Practical Solutions, LLC.
Jifty is distributed under the same terms as Perl itself.

=cut

1;
