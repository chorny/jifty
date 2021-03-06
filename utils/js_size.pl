#!/usr/bin/perl
use strict;
use IPC::Run3 'run3';
use Jifty;
Jifty->new;

=head1 NAME

js_size - summarize the size of javascript used in your jifty app

=head1 SYNOPSIS

  % perl js_size.pl

  % perl js_size.pl /path/to/jsmin

=head1 DESCRIPTION



=cut

my $jsmin = shift ;

my $static_handler = Jifty->handler->view('Jifty::View::Static::Handler');
my $js = "";



my $total = 0;
my $total_minified = 0;
my $size = {};
my $size_minified = {};
for my $file ( @{ Jifty::Web->javascript_libs } ) {
    my $include = $static_handler->file_path( File::Spec->catdir( 'js', $file ) );
    $total += $size->{$file} = -s $include;

    if ($jsmin) {
        my $output = '';
        open my $input, '<', $include;
        run3 [$jsmin], $input, \$output, undef;
        $total_minified += $size_minified->{$file} = length $output;
    }
}

my $min_format = "%6.2f%% (%5.2f%%) %7d (%7d) %s\n";
my $format = "%6.2f%% %7d %s\n";

for my $file ( @{ Jifty::Web->javascript_libs } ) {
    if ($jsmin) {
        printf($min_format,
           ($size->{$file} / $total * 100),
           ($size_minified->{$file} / $total_minified * 100),
           $size->{$file}, $size_minified->{$file}, $file );
    }
    else {
        printf($format,
           ($size->{$file} / $total * 100),
           $size->{$file}, $file );
    }
}

if ($jsmin) {
    printf($min_format,
        100,
        ($total_minified / $total * 100),
        $total, $total_minified, 'total');
}
else {
    printf($format,
        100,
        $total, 'total');
}

