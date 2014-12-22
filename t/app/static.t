
use Statocles::Base 'Test';
use Statocles::Site;
use Statocles::App::Static;
use Mojo::DOM;

my $SHARE_DIR = path( __DIR__ )->parent->child( 'share' );
my $site = Statocles::Site->new(
    title => 'Test site',
    build_store => '.',
    deploy_store => '.',
);

subtest 'constructor' => sub {

    test_constructor(
        "Statocles::App::Static",
        required => {
            url_root => '/',
            store => $SHARE_DIR->child( qw( app static ) ),
        },
    );

};

subtest 'pages' => sub {

    my $app = Statocles::App::Static->new(
        url_root => '/',
        store => $SHARE_DIR->child( qw( app static ) ),
    );

    test_pages(
        $site, $app,

        '/static.txt' => sub {
            my ( $text ) = @_;
            eq_or_diff $text, $SHARE_DIR->child( qw( app static static.txt ) )->slurp_utf8;
        },

        '/static.yml' => sub {
            my ( $text ) = @_;
            eq_or_diff $text, $SHARE_DIR->child( qw( app static static.yml ) )->slurp_utf8;
        },

    );
};

done_testing;