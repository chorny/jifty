package Jifty::Plugin::SkeletonApp::View;

use strict;
use warnings;
use vars qw( $r );

use Jifty::View::Declare -base;

use Scalar::Defer;

=head1 NAME

Jifty::Plugin::SkeletonApp::View

=head1 DESCRIPTION

This somewhat-finished (But not quite) template library implements
Jifty's "pony" Application. It could certainly use some
refactoring. (And some of the menu stuff should get factored out into
a dispatcher or the other plugins that implement it.


=cut

private template 'salutation' => sub {
    div {
    attr {id => "salutation" };
        if (    Jifty->web->current_user->id
            and Jifty->web->current_user->user_object )
        {
            _( 'Hiya, %1.', Jifty->web->current_user->username );
        }
        else {
            _("You're not currently signed in.");
        }
    }
};

private template 'menu' => sub {
    div {
    attr { id => "navigation" };
        Jifty->web->navigation->render_as_menu; };
};

template '__jifty/empty' => sub :Static {
        '';
};


private template 'header' => sub {
    my ($title) = get_current_attr(qw(title));
    Jifty->handler->apache->content_type('text/html; charset=utf-8');
    head { 
        with(
            'http-equiv' => "content-type",
            content      => "text/html; charset=utf-8"
          ),    
          meta {};
        with( name => 'robots', content => 'all' ), meta {};
        title { _($title) };
        Jifty->web->include_css;
        Jifty->web->include_javascript;

        if (Jifty->config->framework('L10N')->{js}) {
            # js l10n
            my $current_lang = Jifty::I18N->get_current_language || 'en';
            outs_raw(qq{<script type="text/javascript">Localization.init({dict_path: '/static/js/dict', lang: '$current_lang'});</script>});
        }
    };
};

private template 'heading_in_wrapper' => sub {
    h1 { attr { class => 'title' }; outs_raw(get('title')) };
};

private template 'keybindings' => sub {
    div { id is "keybindings";
      outs_raw('<script type="text/javascript"><!-- Jifty.KeyBindings.reset() --></script>') };
};

#template 'index.html' => page { { title is _('Welcome to your new Jifty application') } img { src is "/static/images/pony.jpg", alt is _( 'You said you wanted a pony. (Source %1)', 'http://hdl.loc.gov/loc.pnp/cph.3c13461'); }; };

1;
