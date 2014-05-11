package Statocles::App::Blog;
# ABSTRACT: A blog application

use Statocles::Class;
use Statocles::Page;
use Statocles::Page::List;

extends 'Statocles::App';

has source => (
    is => 'ro',
    isa => InstanceOf['Statocles::Store'],
);

has url_root => (
    is => 'ro',
    isa => Str,
    required => 1,
);

has theme => (
    is => 'ro',
    isa => InstanceOf['Statocles::Theme'],
    required => 1,
);

sub post_pages {
    my ( $self ) = @_;
    my @pages;
    for my $doc ( @{ $self->source->documents } ) {
        my $path = join "/", $self->url_root, $doc->path;
        $path =~ s{/{2,}}{/}g;
        $path =~ s{[.]\w+$}{.html};
        push @pages, Statocles::Page->new(
            layout => $self->theme->templates->{site}{layout},
            template => $self->theme->templates->{blog}{post},
            document => $doc,
            path => $path,
        );
    }
    return @pages;
}

sub index {
    my ( $self ) = @_;
    return Statocles::Page::List->new(
        path => join( "/", $self->url_root, 'index.html' ),
        template => $self->theme->template( blog => 'index' ),
        layout => $self->theme->template( site => 'layout' ),
        pages => [ $self->post_pages ],
    );
}

sub pages {
    my ( $self ) = @_;
    return ( $self->post_pages, $self->index );
}

1;