package Statocles::Site;
# ABSTRACT: An entire, configured website

use Statocles::Base 'Class', 'Emitter';
use Scalar::Util qw( blessed );
use Text::Markdown;
use Mojo::URL;
use Mojo::DOM;
use Mojo::Log;
use Statocles::Page::Plain;

=attr title

The site title, used in templates.

=cut

has title => (
    is => 'ro',
    isa => Str,
    default => sub { '' },
);

=attr base_url

The base URL of the site, including protocol and domain. Used mostly for feeds.

This can be overridden by L<base_url in Deploy|Statocles::Deploy/base_url>.

=cut

has base_url => (
    is => 'ro',
    isa => Str,
    default => sub { '/' },
);

=attr theme

The L<theme|Statocles::Theme> for this site. All apps share the same theme.

=cut

has theme => (
    is => 'ro',
    isa => Theme,
    coerce => Theme->coercion,
    default => sub {
        require Statocles::Theme;
        Statocles::Theme->new( store => '::default' );
    },
);

=attr apps

The applications in this site. Each application has a name
that can be used later.

=cut

has apps => (
    is => 'ro',
    isa => HashRef[ConsumerOf['Statocles::App']],
    default => sub { {} },
);

=attr index

The page path to use for the site index. Make sure to include the leading slash
(but C</index.html> is optional). Defaults to C</>, so any app with C<url_root>
of C</> will be the index.

=cut

has index => (
    is => 'ro',
    isa => Str,
    default => sub { '/' },
);

=attr nav

Named navigation lists. A hash of arrays of hashes with the following keys:

    title - The title of the link
    href - The href of the link

The most likely name for your navigation will be C<main>. Navigation names
are defined by your L<theme|Statocles::Theme>. For example:

    {
        main => [
            {
                title => 'Blog',
                href => '/blog',
            },
            {
                title => 'Contact',
                href => '/contact.html',
            },
        ],
    }

=cut

has _nav => (
    is => 'ro',
    isa => LinkHash,
    coerce => LinkHash->coercion,
    default => sub { {} },
    init_arg => 'nav',
);

=attr build_store

The L<store|Statocles::Store> object to use for C<build()>. This is a workspace
and will be rebuilt often, using the C<build> and C<daemon> commands. This is
also the store the C<daemon> command reads to serve the site.

=cut

has build_store => (
    is => 'ro',
    isa => Store,
    default => sub {
        my $path = Path::Tiny->new( '.statocles', 'build' );
        if ( !$path->is_dir ) {
            # Automatically make the build directory
            $path->mkpath;
        }
        return Store->coercion->( $path );
    },
    coerce => sub {
        my ( $arg ) = @_;
        if ( !ref $arg && !-d $arg ) {
            # Automatically make the build directory
            Path::Tiny->new( $arg )->mkpath;
        }
        return Store->coercion->( $arg );
    },
);

=attr deploy

The L<deploy object|Statocles::Deploy> to use for C<deploy()>. This is
intended to be the production deployment of the site. A build gets promoted to
production by using the C<deploy> command.

=cut

has _deploy => (
    is => 'ro',
    isa => ConsumerOf['Statocles::Deploy'],
    required => 1,
    init_arg => 'deploy',
    coerce => sub {
        if ( ( blessed $_[0] && $_[0]->isa( 'Path::Tiny' ) ) || !ref $_[0] ) {
            require Statocles::Deploy::File;
            return Statocles::Deploy::File->new(
                path => $_[0],
            );
        }
        return $_[0];
    },
);

=attr data

A hash of arbitrary data available to theme templates. This is a good place to
put extra structured data like social network links or make easy customizations
to themes like header image URLs.

=cut

has data => (
    is => 'ro',
    isa => HashRef,
    default => sub { {} },
);

=attr log

A L<Mojo::Log> object to write logs to. Defaults to STDERR.

=cut

has log => (
    is => 'ro',
    isa => InstanceOf['Mojo::Log'],
    lazy => 1,
    default => sub {
        Mojo::Log->new( level => 'warn' );
    },
);

=attr markdown

The Text::Markdown object to use to turn Markdown into HTML. Defaults to a
plain Text::Markdown object.

Any object with a "markdown" method will work here.

=cut

has markdown => (
    is => 'ro',
    isa => HasMethods['markdown'],
    default => sub { Text::Markdown->new },
);

# The current deploy we're writing to
has _write_deploy => (
    is => 'rw',
    isa => ConsumerOf['Statocles::Deploy'],
    clearer => '_clear_write_deploy',
);

=method BUILD

Register this site as the global site.

=cut

sub BUILD {
    my ( $self ) = @_;

    $Statocles::SITE = $self;
    for my $app ( values %{ $self->apps } ) {
        $app->site( $self );
    }
}

=method app

    my $app = $site->app( $name );

Get the app with the given C<name>.

=cut

sub app {
    my ( $self, $name ) = @_;
    return $self->apps->{ $name };
}

=method nav

    my @links = $site->nav( $key );

Get the list of links for the given nav C<key>. Each link is a
L<Statocles::Link> object.

    title - The title of the link
    href - The href of the link

If the named nav does not exist, returns an empty list.

=cut

sub nav {
    my ( $self, $name ) = @_;
    return $self->_nav->{ $name } ? @{ $self->_nav->{ $name } } : ();
}

=method build

    $site->build( %options );

Build the site in its build location. The C<%options> hash is passed in to every
app's C<pages> method, allowing for customization of app behavior based on
command-line.

=cut

our %PAGE_PRIORITY = (
    'Statocles::Page::File' => -100,
);

sub build {
    my ( $self, %options ) = @_;

    my $store = $self->build_store;

    # Remove all pages from the build directory first
    $_->remove_tree for $store->path->children;

    my $apps = $self->apps;
    my @pages;
    my %seen_paths;
    my %args = (
        site => $self,
    );

    # Collect all the pages for this site
    # XXX: Should we allow sites without indexes?
    my $index_path = $self->index;
    if ( $index_path && $index_path !~ m{^/} ) {
        $self->log->warn(
            sprintf 'site "index" property should be absolute path to index page (got "%s")',
            $self->index,
        );
    }

    for my $app_name ( keys %{ $apps } ) {
        my $app = $apps->{$app_name};

        my @app_pages = $app->pages( %options );

        # DEPRECATED: Index as app name
        if ( $app_name eq $index_path ) {

            die sprintf 'ERROR: Index app "%s" did not generate any pages' . "\n", $self->index
                unless @app_pages;

            # Rename the app's page so that we don't get two pages with identical
            # content, which is bad for SEO
            $app_pages[0]->path( '/index.html' );
        }

        for my $page ( @app_pages ) {
            my $path = $page->path;

            if ( $path =~ m{^$index_path(?:/index[.]html)?$} ) {
                # Rename the app's page so that we don't get two pages with identical
                # content, which is bad for SEO
                $self->log->debug(
                    sprintf 'Found index page "%s" from app "%s"',
                    $path,
                    $app_name,
                );
                $path = '/index.html';
                $page->path( '/index.html' );
            }

            if ( $seen_paths{ $path }{ $app_name } ) {
                $self->log->warn(
                    sprintf 'Duplicate page with path "%s" from app "%s"',
                        $path,
                        $app_name,
                );
                next;
            }

            $seen_paths{ $path }{ $app_name } = $page;
        }
    }

    # XXX: Do we want to allow sites with no index page ever?
    if ( $self->index && !exists $seen_paths{ '/index.html' } ) {
        my $index_document = $self->index;
        unless ( $index_document =~ s{[.]html?}{.markdown} ) {
            $index_document .= '/index.markdown';
        }
        die sprintf qq{ERROR: Index path "%s" does not exist. Do you need to create "%s"?},
            $self->index,
            $index_document;
    }

    for my $path ( keys %seen_paths ) {
        my %seen_apps = %{ $seen_paths{$path} };
        # Warn about pages generated by more than one app
        if ( keys %seen_apps > 1 ) {
            my @seen_app_names = map { $_->[0] }
                            sort { $b->[1] <=> $a->[1] }
                            map { [ $_, $PAGE_PRIORITY{ ref $seen_apps{ $_ } } || 0 ] }
                            keys %seen_apps
                            ;

            $self->log->warn(
                sprintf 'Duplicate page "%s" from apps: %s. Using %s',
                    $path,
                    join( ", ", @seen_app_names ),
                    $seen_app_names[0],
            );

            push @pages, $seen_apps{ $seen_app_names[0] };
        }
        else {
           push @pages, values %seen_apps;
        }
    }

    $self->emit(
        'before_build_write',
        class => 'Statocles::Event::Pages',
        pages => \@pages,
    );

    # Rewrite page content to add base URL
    my $base_url = $self->base_url;
    if ( $self->_write_deploy ) {
        $base_url = $self->_write_deploy->base_url || $base_url;
    }
    my $base_path = Mojo::URL->new( $base_url )->path;
    $base_path =~ s{/$}{};

    # DEPRECATED: Index without leading / is an index app
    my $index_root  = $self->index =~ m{^/} ? $self->index
                    : $self->index ? $apps->{ $self->index }->url_root : '';
    $index_root =~ s{/index[.]html$}{};

    for my $page ( @pages ) {
        my $content = $page->render( %args );

        if ( !ref $content ) {
            my $dom = Mojo::DOM->new( $content );
            for my $attr ( qw( src href ) ) {
                for my $el ( $dom->find( "[$attr]" )->each ) {
                    my $url = $el->attr( $attr );
                    next unless $url =~ m{^/(?:[^/]|$)};

                    # Rewrite links to the index app's index page
                    if ( $index_root && $url =~ m{^$index_root(?:/index[.]html)?$} ) {
                        $url = '/';
                    }

                    if ( $base_path =~ /\S/ ) {
                        $url = join "", $base_path, $url;
                    }

                    $el->attr( $attr, $url );
                }
            }
            $content = $dom->to_string;
        }

        $store->write_file( $page->path, $content );
    }

    # Build the sitemap.xml
    # html files only
    my @indexed_pages = grep { $_->path =~ /[.]html?$/ } @pages;
    my $tmpl = $self->theme->template( site => 'sitemap.xml' );
    my $sitemap = Statocles::Page::Plain->new(
        path => '/sitemap.xml',
        content => $tmpl->render( site => $self, pages => \@indexed_pages ),
    );
    push @pages, $sitemap;
    $store->write_file( 'sitemap.xml', $sitemap->render );

    # robots.txt is the best way for crawlers to automatically discover sitemap.xml
    # We should do more with this later...
    my $robots_tmpl = $self->theme->template( site => 'robots.txt' );
    my $robots = Statocles::Page::Plain->new(
        path => '/robots.txt',
        content => $robots_tmpl->render( site => $self ),
    );
    push @pages, $robots;
    $store->write_file( 'robots.txt', $robots->render );

    # Add the theme
    for my $page ( $self->theme->pages ) {
        push @pages, $page;
        $store->write_file( $page->path, $page );
    }

    $self->emit( build => class => 'Statocles::Event::Pages', pages => \@pages );

    return;
}

=method deploy

    $site->deploy( %options );

Deploy the site to its destination. The C<%options> are passed to the appropriate
L<deploy object|Statocles::Deploy>.

=cut

sub deploy {
    my ( $self, %options ) = @_;
    $self->_write_deploy( $self->_deploy );
    $self->build( %options );
    $self->_deploy->deploy( $self->build_store, %options );
    $self->_clear_write_deploy;
}

=method url

    my $url = $site->url( $page_url );

Get the full URL to the given path by prepending the C<base_url>.

=cut

sub url {
    my ( $self, $path ) = @_;
    my $base    = $self->_write_deploy && $self->_write_deploy->base_url
                ? $self->_write_deploy->base_url
                : $self->base_url;

    # Remove index.html from the end of the path, since it's redundant
    $path =~ s{/index[.]html$}{/};

    # Remove the / from both sides of the join so we don't double up
    $base =~ s{/$}{};
    $path =~ s{^/}{};

    return join "/", $base, $path;
}

1;
__END__

=head1 SYNOPSIS

    my $site = Statocles::Site->new(
        title => 'My Site',
        nav => [
            { title => 'Home', href => '/' },
            { title => 'Blog', href => '/blog' },
        ],
        apps => {
            blog => Statocles::App::Blog->new( ... ),
        },
    );

    $site->deploy;

=head1 DESCRIPTION

A Statocles::Site is a collection of L<applications|Statocles::App>.

=head1 EVENTS

The site object exposes the following events.

=head2 before_build_write

This event is fired after the pages have been built by the apps, but before
any page is written to the C<build_store>.

You can use this event to add new pages or edit the pages already created.

The event will be a
L<Statocles::Event::Pages|Statocles::Event/Statocles::Event::Pages> object
containing all the pages built by the apps.

=head2 build

This event is fired after the site has been built and the pages written to the
C<build_store>.

The event will be a
L<Statocles::Event::Pages|Statocles::Event/Statocles::Event::Pages> object
containing all the pages built by the site.

