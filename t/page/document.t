
use Test::Lib;
use My::Test;
my $SHARE_DIR = path( __DIR__ )->parent->child( 'share' );

use Statocles::Document;
use Statocles::Page::Document;
use Text::Markdown;
use Statocles::Site;
use Statocles::App::Basic;
my $site = Statocles::Site->new(
    deploy => tempdir,
    title => 'Test Site',
    theme => $SHARE_DIR->child(qw( theme )),
);
my $md = Text::Markdown->new;

my $doc = Statocles::Document->new(
    path => '/required.markdown',
    title => 'Page Title',
    author => 'preaction',
    tags => [qw( foo bar baz )],
    date => DateTime::Moonpig->new( time - 600 ),
    images => {
        title => {
            src => '/foo.jpg',
        },
    },
    links => {
        alternate => [
            {
                href => '/foo.html',
            },
        ],
    },
    data => {
        foo => 'bar',
    },
    content => <<'MARKDOWN',
# Subtitle

This is a paragraph of markdown.

## Subtitle 2

This is another paragraph of markdown.

<%= "hello" %>

---

This is a second section of content

MARKDOWN
);

my $expect_content = $md->markdown( <<'MARKDOWN' );
# Subtitle

This is a paragraph of markdown.

## Subtitle 2

This is another paragraph of markdown.

hello

---

This is a second section of content
MARKDOWN

my @expect_sections = (
    $md->markdown( <<'MARKDOWN' ),
# Subtitle

This is a paragraph of markdown.

## Subtitle 2

This is another paragraph of markdown.

hello
MARKDOWN

    $md->markdown( <<'MARKDOWN' ),
This is a second section of content
MARKDOWN

);

subtest 'constructor' => sub {

    test_constructor(
        'Statocles::Page::Document',
        required => {
            path => '/path/to/page.html',
            document => $doc,
        },
        default => {
            site => $Statocles::SITE,
            search_change_frequency => 'weekly',
            search_priority => 0.5,
            layout => sub {
                isa_ok $_, 'Statocles::Template';
                is $_->content, '<%= content %>';
            },
            template => sub {
                isa_ok $_, 'Statocles::Template';
                is $_->content, '<%= content %>';
            },
            title => $doc->title,
            author => $doc->author,
            date => $doc->date,
            _images => $doc->images,
            _links => $doc->links,
            data => { foo => 'bar' },
        },
    );

    subtest 'missing document fields default to empty string' => sub {
        my $required_doc = Statocles::Document->new(
            path => '/required.markdown',
        );
        test_constructor(
            'Statocles::Page::Document',
            required => {
                path => '/path/to/page.html',
                document => $required_doc,
            },
            default => {
                title => '',
                author => Statocles::Person->new( name => '' ),
            },
        );
    };
};

subtest 'page date overridden by published date' => sub {
    my $dt = DateTime::Moonpig->now( time_zone => 'local' );
    my $page = Statocles::Page::Document->new(
        document => $doc,
        path => '/path/to/page.html',
        date => $dt,
    );

    isa_ok $page->date, 'DateTime::Moonpig';
    is $page->date->datetime, $dt->datetime;
};

subtest 'document template/layout override' => sub {
    my $doc = Statocles::Document->new(
        path => '/required.markdown',
        title => 'Page Title',
        content => 'Page content',
        template => '/document/recipe.html',
        layout => '/layout/logo.html',
    );

    my $page = Statocles::Page::Document->new(
        path => '/path/to/doc.html',
        site => $site,
        document => $doc,
        template => '<%= $content %>', # will be overridden
        layout => '<%= $content %>', # will be overridden
    );

    my $output = $page->render;
    my $expect = "Logo layout\nRecipe template\nPage Title\n<p>Page content</p>\n\n\n";
    eq_or_diff $output, $expect;
};

subtest 'template coercion' => sub {

    subtest 'template' => sub {
        my $tp = DateTime::Moonpig->now( time_zone => 'local' );

        my $page = Statocles::Page::Document->new(
            document => $doc,
            path => '/path/to/page.html',
            date => $tp,
            template => join( ' ',
                ( map { "<\%= \$self->$_ \%>" } qw( date path ) ),
                ( map { "<\%= \$doc->$_ \%>" } qw( title author ) ),
                ( map { "<\%= \$$_ \%>" } qw( extra_data ) ),
                '<%= $content %>',
            ),
            data => {
                extra_data => 'This is extra data',
            },
        );

        my $output = $page->render;
        my $expect = join " ", $page->date, $page->path, $doc->title, $doc->author,
            $page->data->{extra_data},
            $expect_content . "\n\n";
        eq_or_diff $output, $expect;
    };

    subtest 'layout' => sub {
        my $page = Statocles::Page::Document->new(
            document => $doc,
            path => '/path/to/page.html',
            template => join( ' ',
                '<%= $self->path %>',
                ( map { "<\%= \$doc->$_ \%>" } qw( title author ) ),
                '<%= $content %>',
            ),
            layout => 'HEAD <%= $content %> FOOT',
        );

        my $output = $page->render;
        my $expect = join " ", 'HEAD', $page->path, $doc->title, $doc->author,
            $expect_content . "\n", 'FOOT' . "\n";
        eq_or_diff $output, $expect;
    };
};

subtest 'content sections' => sub {
    my $page = Statocles::Page::Document->new(
        document => $doc,
        path => '/path/to/page.html',
        template => <<'ENDTEMPLATE',
% my @sections = $self->sections;
<%= $sections[0] %>
% if ( @sections > 1 ) {
MORE...
% }
ENDTEMPLATE
    );

    my $output = $page->render;
    my @sections = split /\n---\n/, $doc->content;
    my $expect = join "\n", $expect_sections[0], "MORE...", "", "";
    eq_or_diff $output, $expect;

    subtest 'scalar context' => sub {
        is scalar $page->sections, 2, 'scalar context returns 2 sections';
    };

    subtest 'index arguments' => sub {
        subtest 'one section' => sub {
            my @sections = $page->sections( 0 );
            is scalar @sections, 1, '1 section returned';
            eq_or_diff $sections[0], $expect_sections[0], 'section is correct';
        };

        subtest 'multiple sections' => sub {
            my @sections = $page->sections( 0..1 );
            is scalar @sections, 2, '2 sections returned';
            eq_or_diff $sections[0], $expect_sections[0], 'section 0 is correct';
            eq_or_diff $sections[1], $expect_sections[1], 'section 1 is correct';
        };
    };
};

subtest 'page tags' => sub {
    my $page = Statocles::Page::Document->new(
        document => $doc,
        path => '/path/to/page.html',
        tags => [
            {
                title => 'foo',
                href => '/path/to/foo.html',
            },
            {
                title => 'bar',
                href => '/path/to/bar.html',
            },
            {
                title => 'baz',
                href => '/path/to/baz.html',
            },
        ],
        template => <<'ENDTEMPLATE',
% for my $link ( $self->tags ) {
<%= $link->title %>: <%= $link->href %>
% }
ENDTEMPLATE
    );

    my $output = $page->render;
    my $expect = join "\n", ( map { join ": ", $_->title, $_->href } $page->tags ), "", "";
    eq_or_diff $output, $expect;

    subtest 'default' => sub {
        my $page = Statocles::Page::Document->new(
            document => $doc,
            path => '/path/to/page.html',
            template => <<'ENDTEMPLATE',
% for my $link ( $self->tags ) {
<%= $link->title %>: <%= $link->href %>
% }
ENDTEMPLATE
        );
        my $output;
        lives_ok { $output = $page->render };
        is $output, "\n";
    };
};

subtest 'document template' => sub {
    my $site = Statocles::Site->new(
        theme => $SHARE_DIR->child( 'theme' ),
        deploy => tempdir,
    );

    my $doc = Statocles::Document->new(
        path => '/required.markdown',
        title => 'Page Title',
        data => 'Hello, Darling',
        store => $SHARE_DIR->child( 'store', 'docs' ),
        content => <<'MARKDOWN',
# Subtitle

This is a paragraph of markdown.

%= include "include/test.markdown.ep", title => $self->title
%= $self->data
%= $page->path
MARKDOWN
    );

    my $page = Statocles::Page::Document->new(
        document => $doc,
        path => '/path/to/page.html',
    );

    my $expect = <<'ENDHTML';
<h1>Subtitle</h1>

<p>This is a paragraph of markdown.</p>

<h1>Page Title</h1>

<p>Hello, Darling
/path/to/page.html</p>


ENDHTML

    eq_or_diff $page->render, $expect;

    subtest 'include in document directory' => sub {

        my $doc = Statocles::Document->new(
            path => '/required.markdown',
            title => 'Page Title',
            data => 'Hello, Darling',
            store => $SHARE_DIR->child( 'store', 'docs' ),
            content => <<'MARKDOWN',
%= include "no-frontmatter.markdown"
MARKDOWN
        );

        my $page = Statocles::Page::Document->new(
            document => $doc,
            path => '/path/to/page.html',
        );

        my $expect = <<'ENDHTML';
<h1>This Document has no frontmatter!</h1>

<p>Documents are not required to have frontmatter!</p>


ENDHTML

        eq_or_diff $page->render, $expect;
    };

    subtest 'include in parent directory' => sub {

        my $doc = Statocles::Document->new(
            path => '/links/alternate_single.markdown',
            title => 'Page Title',
            data => 'Hello, Darling',
            store => $SHARE_DIR->child( 'store', 'docs' ),
            content => <<'MARKDOWN',
%= include "../no-frontmatter.markdown"
MARKDOWN
        );

        my $page = Statocles::Page::Document->new(
            document => $doc,
            path => '/path/to/page.html',
        );

        my $expect = <<'ENDHTML';
<h1>This Document has no frontmatter!</h1>

<p>Documents are not required to have frontmatter!</p>


ENDHTML

        eq_or_diff $page->render, $expect;
    };

    subtest 'disable content template processing' => sub {
        my $site_disabled = Statocles::Site->new(
            theme => $SHARE_DIR->child( 'theme' ),
            deploy => tempdir,
            disable_content_template => 1,
        );

        my $doc = Statocles::Document->new(
            path => '/required.markdown',
            title => 'Page Title',
            data => 'Hello, Darling',
            store => $SHARE_DIR->child( 'store', 'docs' ),
            content => '%= "Hello"',
        );

        my $doc_enabled = Statocles::Document->new(
            path => '/required.markdown',
            title => 'Page Title',
            data => 'Hello, Darling',
            store => $SHARE_DIR->child( 'store', 'docs' ),
            content => '%= "Hello"',
            disable_content_template => 0,
        );

        my $doc_disabled = Statocles::Document->new(
            path => '/required.markdown',
            title => 'Page Title',
            data => 'Hello, Darling',
            store => $SHARE_DIR->child( 'store', 'docs' ),
            content => '%= "Hello"',
            disable_content_template => 1,
        );

        my $app = Statocles::App::Basic->new(
            url_root => '/',
            store => $SHARE_DIR->child( 'app', 'blog' ),
        );

        my $app_disabled = Statocles::App::Basic->new(
            url_root => '/',
            store => $SHARE_DIR->child( 'app', 'blog' ),
            disable_content_template => 1,
        );

        my $app_enabled = Statocles::App::Basic->new(
            url_root => '/',
            store => $SHARE_DIR->child( 'app', 'blog' ),
            disable_content_template => 0,
        );

        my $test = sub {
            my ( $site, $app, $doc, $disabled ) = @_;
            my $page = Statocles::Page::Document->new(
                site => $site,
                app => $app,
                document => $doc,
                path => '/path/to/page.html',
            );
            if ( $disabled ) {
                is $page->render, qq{<p>%= "Hello"</p>\n\n\n}, 'content template is disabled';
            }
            else {
                is $page->render, qq{<p>Hello</p>\n\n\n}, 'content template is enabled';
            }
        };

        subtest '... by site' => $test, $site_disabled, $app, $doc, 1;
        subtest '... by app' => $test, $site, $app_disabled, $doc, 1;
        subtest '... by doc' => $test, $site, $app, $doc_disabled, 1;
        subtest '... by app but overridden by doc' => $test, $site, $app_disabled, $doc_enabled, 0;
        subtest '... by site but overridden by doc' => $test, $site_disabled, $app, $doc_enabled, 0;
        subtest '... by site but overridden by app' => $test, $site_disabled, $app_enabled, $doc, 0;
    };

};

done_testing;
