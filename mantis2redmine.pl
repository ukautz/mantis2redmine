#!/usr/bin/env perl

=head1 NAME

mantis2redmine.pl - Import Mantis database into Redmine

=head1 DESCRIPTION

This script imports provided Mantis database into existing Redmine database without destroying existing content in the redmine database. The idea is a non-destructive migration. Via user interaction re-mappings of mantis users, priojects and so on to Redmine equivalents can be performed.

Tested with:
    Redmine 2.6.6 stable
    Mantis 1.2.19 stable

Inspired by "migrate_from_mantis.rake" from the Redmine project.

=head1 DEPENDENCIES

    Getopt::Long
    DBIx::Simple
    YAML

This would require the following packages on a debian system

    perl-modules
    libdbix-simple-perl
    libyaml-perl

=head1 SYNOPSIS

    mantis2redmine.pl -c mantis2redmine.config --load_maps --dry-run

=head1 FAQ

=over

=item * It says "Load from file" ..

You already ran this script once (eg in dry-run-mode). It will create store-<name>.map files within the current directory to save your answers. If you want to answer one (or all) of the mappings again simply remove the corresponding store-file (name should be self-explanatory).

=back

=head1 AUTHOR

=over

=item * Ulrich Kautz <uk@fortrabbit.de>

=item * Philipp Schüle <p.schuele@metaways.de>

=back

=head1 COPYRIGHT

Copyright (c) 2010. See L</AUTHOR>

This program is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

See http://www.perl.com/perl/misc/Artistic.html

=head1 WARRANTIES

None. Make a backup!

=head1 Changelog

modified by Philipp Schüle <p.schuele@metaways.de>

did the following:
    - import categories / do not use the trackers as categories
    - use severity column to determine the tracker
    - skip attachments because they might be  in the DB

TODO
    - make it possible to switch between categories -> categories / categories -> tracker import (via config/cli param)

=cut


# Load Modules

use strict;
use warnings;

use Getopt::Long;
use DBIx::Simple;
use Data::Dumper;
use YAML;

use version 0.74; our $VERSION = qv(v0.3.1);

# Unbuffered output
$| = 1;


# Read commandline options

my %opt;
GetOptions(
    "dry_run|n" => \( my $DRY = 0 ),
    "help|h"    => \( $opt{ help } = 0 ),

    "mantis_db_host=s"  => \( $opt{ mantis_db_host }  = "localhost" ),
    "mantis_db_name=s"  => \( $opt{ mantis_db_name }  = "mantis" ),
    "mantis_db_login=s" => \( $opt{ mantis_db_login } = "" ),
    "mantis_db_pass=s"  => \( $opt{ mantis_db_pass }  = "" ),

    "redmine_db_host=s"  => \( $opt{ redmine_db_host }  = "localhost" ),
    "redmine_db_name=s"  => \( $opt{ redmine_db_name }  = "redmine" ),
    "redmine_db_login=s" => \( $opt{ redmine_db_login } = "" ),
    "redmine_db_pass=s"  => \( $opt{ redmine_db_pass }  = "" ),

    "load_maps"  => \( $opt{ load_maps } ),
    "config|c=s" => \( $opt{ config } = "" ),

    "category_source" => \( $opt{ category_source } = "categories" ),

    "attachment_dir=s" => \( $opt{ attachment_dir } = "attachments" )
);


# Print help

die <<HELP if $opt{ help };
mantis2redmine.pl v$VERSION
    by Ulrich Kautz <uk\@fortrabbit.de>

Usage: $0 [options]
Options
    --help | -h
        Show this help
    --dry_run | -n
        Dont migrate anything.. just try to
    --load_maps
        Load map files which are created on generation, even on dry-run.
        You can re-use them later on.. for lazy people.
    --config | -c <path to config>
        Each parameter can be provided via config file .. eg:
            mantis_db_host = localhost
            mantis_db_name = mantis
        and so on ..
    --attachment_dir <path>
        Direcory for outputting any attachment file.
        default: attachments (in current dir)

    Import flavor:
    --category-source <source>
        You can either use "categories" or "trackers" as source for your
        newly created redmine categories.
        Default: "categories"

    Mantis Database:
    --mantis_db_host <hostname>
        default: localhost
    --mantis_db_name <database>
        default: mantis
    --mantis_db_login <login>
    --mantis_db_pass <password>

    Redmine Database:
    --redmine_db_host <hostname>
        default: localhost
    --redmine_db_name <database>
        default: redmine
    --redmine_db_login <login>
    --redmine_db_pass <password>

HELP


# Init

# read config file for options ..
%opt = ( %opt, read_config( $opt{ config } ) ) if $opt{ config };

# check attribs
my @check_err = ();
foreach my $type( qw/ mantis redmine / ) {
    foreach my $key( qw/ host name login pass / ) {
        push @check_err, "--$type\_db_$key" unless $opt{ "$type\_db_$key" };
    }
}
die "Missing: \n  ". join( ", ", @check_err ). "\nUse --help for all options\n" if @check_err;

# check attachment table
die "No such directory '$opt{ attachment_dir }'.. please created!\n"
    unless (-d $opt{ attachment_dir } || $opt{ attachments_in_db });

# check category-source
die "Not allowed --category-source '$opt{ category_source }', use one of 'categories' or 'trackers'\n"
    unless $opt{ category_source } =~ /^(?:categories|trackers)$/;

# display warning
unless ( $DRY || read_in( "Are you sure you? Do you have a backup of your important data?\n  eg: mysqldump --add-drop-table --lock-tables --complete-insert --create-options -u$opt{ redmine_db_login } -p$opt{ redmine_db_pass } -h$opt{ redmine_db_host } $opt{ redmine_db_name }\nType uppercase YES if you want to continue" ) eq "YES" ) {
    die "Make a backup!\n";
}

# open dbi
my $dbix_mantis = DBIx::Simple->connect(
    'DBI:mysql:database='. $opt{ mantis_db_name }. ';host='. $opt{ mantis_db_host },
    $opt{ mantis_db_login }, $opt{ mantis_db_pass },
    { RaiseError => 1, mysql_enable_utf8 => 1},
);
my $dbix_redmine = DBIx::Simple->connect(
    'DBI:mysql:database='. $opt{ redmine_db_name }. ';host='. $opt{ redmine_db_host },
    $opt{ redmine_db_login }, $opt{ redmine_db_pass },
    { RaiseError => 1, mysql_enable_utf8 => 1}
);


# Prepare user-interactive import

# import mappings
my %map = ();

# build list of import modules
my @import_modules = (
    qw/ stati priorities roles custom_fields relations projects versions /,
    $opt{ category_source },
    qw/ users /
);

# run import
foreach my $import( @import_modules ) {
    my $meth = "import_$import";
    print " *** ". ucfirst( $import ). " ***\n\n";
    {
        no strict 'refs';
        $map{ $import } = $opt{ load_maps } && -f "store-$import.map"
            ? do {
                print "-> Load from file\n";
                load_map( $import )
            }
            : do {
                my $ref = $meth->();
                save_map( $import => $ref );
                $ref;
            }
        ;
    }
    print "\n\n";
}


# Run import

perform_import( \%map );



=head1 METHODS


=head2 import_stati

Rewrite the Mantis static stati to Redmine database stati.

User interactive.

=cut

sub import_stati {
    my %redmine_stati = map {
        ( $_->{ position } => $_ )
    } $dbix_redmine->query( 'SELECT id, name, position FROM issue_statuses' )->hashes;
    my $default_ref = $redmine_stati{ 1 };

    my %mantis_stati = (
        10 => [ "new", $redmine_stati{ 1 } ], # new
        20 => [ "feedback", $redmine_stati{ 4 } || $default_ref ], # feedback
        30 => [ "acknowledged", $redmine_stati{ 1 } ], # acknowledged
        40 => [ "confirmed", $redmine_stati{ 1 } ], # confirmed
        50 => [ "assigned", $redmine_stati{ 2 } || $default_ref ], # assigned
        80 => [ "resolved", $redmine_stati{ 3 } || $default_ref ], # resolved
        90 => [ "closed", $redmine_stati{ 5 } || $default_ref ]  # closed
    );

    return create_map( 'Status', \%mantis_stati, \%redmine_stati, $default_ref, 'position' );
}


=head2 import_priorities

Rewrite the Mantis static priorities to Redmine database priorities.

User interactive.

=cut

sub import_priorities {
    my %redmine = map {
        ( $_->{ position } => $_ )
    } $dbix_redmine->query( 'SELECT id, name, position FROM enumerations WHERE type = ?', 'IssuePriority' )->hashes;
    my $default_ref = $redmine{ 1 };

    my %mantis = (
        10 => [ 'none', $redmine{ 1 } ], # none
        20 => [ 'low', $redmine{ 1 } ], # low
        30 => [ 'normal', $redmine{ 2 } || $default_ref ], # normal
        40 => [ 'high', $redmine{ 3 } || $default_ref ], # high
        50 => [ 'urgent', $redmine{ 4 } || $default_ref ], # urgent
        60 => [ 'immediate', $redmine{ 5 } || $default_ref ]  # immediate
    );

    return create_map( 'Priority', \%mantis, \%redmine, $default_ref, 'position' );
}


=head2 import_roles

Rewrite the Mantis static roles to Redmine database roles.

User interactive.

=cut

sub import_roles {
    my %redmine = map {
        ( $_->{ position } => $_ )
    } $dbix_redmine->query( 'SELECT id, name, position FROM roles' )->hashes;
    my $default_ref = $redmine{ scalar keys %redmine };

    my %mantis = (
        10 => [ 'viewer', $default_ref ],   # viewer
        25 => [ 'reporter', $redmine{ 5 } || $default_ref ],   # reporter
        40 => [ 'updater', $default_ref ],   # updater
        55 => [ 'developer', $redmine{ 4 } || $default_ref ], # developer
        70 => [ 'manager', $redmine{ 3 } || $default_ref ],   # manager
        90 => [ 'administrator', $redmine{ 3 } || $default_ref ]    # administrator
    );

    return create_map( 'Role', \%mantis, \%redmine, $default_ref, 'position' );
}


=head2 import_custom_fields

Rewrite the Mantis static custom field types to Redmine static custom field types.

Non interactive.

=cut

sub import_custom_fields {
    return {
        0 => 'string', # String
        1 => 'int',    # Numeric
        2 => 'int',    # Float
        3 => 'list',   # Enumeration
        4 => 'string', # Email
        5 => 'bool',   # Checkbox
        6 => 'list',   # List
        7 => 'list',   # Multiselection list
        8 => 'date',   # Date
    };
}


=head2 import_relations

Rewrite the Mantis static relation types to Redmine static relation types.

Non interactive.

=cut

sub import_relations {
    return {
        1 => 'relates',    # related to
        2 => 'blocked',    # parent of
        3 => 'blocks',     # child of
        0 => 'duplicates', # duplicate of
        4 => 'duplicated'  # has duplicate
    };
}


=head2 import_projects

Rewrite the Mantis projects to Redmine projects.

Non interactive.

=cut

sub import_projects {
    my %mantis = map {
        $_->{ name } => $_->{ name };
        ( $_->{ id } => $_ );
    } $dbix_mantis->query( 'SELECT id, name, description FROM mantis_project_table' )->hashes;
    my ( $first_mantis_id ) = sort keys %mantis;
    die "Did not find any mantis projects\n"
        unless $first_mantis_id;

    my %redmine = map {
        ( $_->{ id } => $_ );
    } $dbix_redmine->query( 'SELECT id, name FROM projects' )->hashes;
    my ( $first_id ) = sort keys %redmine;

    my $mantis_ref = { map {
        ( $_ => [ $mantis{ $_ }->{ name }, { name => 'new', id => -1 } ] )
    } keys %mantis };
    my $redmine_ref = { map {
        ( $_ => $redmine{ $_ } )
    } keys %redmine };
    premap( $mantis_ref, $redmine_ref, 'name' );

    my $default_ref = $first_id
        ? $redmine{ $first_id }
        : { id => -1, name => '*no project found in redmine*' }
    ;

    my $new_ref = create_map( 'Project', $mantis_ref, $redmine_ref, $default_ref, 'id', {
        allow_new     => 1,
        print_mantis  => 1,
        print_redmine => 1
    } );

    my $ref = update_maps( $new_ref, \%mantis );
    print Dumper $ref;
    return $ref;
    #return update_maps( $new_ref, \%mantis );
}


=head2 import_versions

Rewrite the Mantis projects to Redmine projects.

User interactive.

=cut

sub import_versions {

    my %mantis = map {
        $_->{ name } = substr( delete $_->{ version }, 0, 30 );
        ( $_->{ id } => $_ );
    } $dbix_mantis->query( 'SELECT id, version, description, project_id, released, FROM_UNIXTIME( date_order, \'%Y-%m-%d\' ) as effective_date FROM mantis_project_version_table' )->hashes;

    my %redmine = map {
        ( $_->{ id } => $_ );
    } $dbix_redmine->query( 'SELECT id, name FROM versions' )->hashes;
    my ( $first_id ) = sort keys %redmine;


    my $mantis_ref = { map {
        ( $_ => [ $mantis{ $_ }->{ name }, { name => 'new', id => -1 } ] )
    } keys %mantis };
    my $redmine_ref = { map {
        ( $_ => $redmine{ $_ } )
    } keys %redmine };
    premap( $mantis_ref, $redmine_ref, 'name' );

    my $default_ref = $first_id
        ? $redmine{ $first_id }
        : { id => -1, name => '*no version found in redmine*' }
    ;

    my $new_ref = create_map( 'Version', $mantis_ref, $redmine_ref, $default_ref, 'id', {
        allow_new     => 1,
        print_mantis  => 1,
        print_redmine => 1
    } );

    return update_maps( $new_ref, \%mantis );
}

=head2 import_trackers

Maps Mantis categories to Redmine trackers.

User interactive.

=cut

sub import_trackers {
    my %mantis = map {
        ( $_->{ id } => $_ );
    } $dbix_mantis->query( 'SELECT id, category as name, project_id FROM mantis_category_table' )->hashes;

    my %redmine = map {
        ( $_->{ id } => $_ );
    } $dbix_redmine->query( 'SELECT id, name FROM trackers' )->hashes;
    my ( $first_id ) = sort keys %redmine;

    my $mantis_ref = { map {
        ( $_ => [ $mantis{ $_ }->{ name }, { name => 'new', id => -1 } ] )
    } keys %mantis };
    my $redmine_ref = { map {
        ( $_ => $redmine{ $_ } )
    } keys %redmine };
    premap( $mantis_ref, $redmine_ref, 'name' );

    my $new_ref = create_map( 'Tracker', $mantis_ref, $redmine_ref, $redmine{ $first_id }, 'id', {
       allow_new     => 1,
       print_mantis  => 1,
       print_redmine => 1
    } );

    return update_maps( $new_ref, \%mantis );
}

=head2 import_categories

Maps Mantis categories to Redmine categories.

User interactive.

=cut

sub import_categories {
    my %mantis = map {
        ( $_->{ id } => $_ );
    } $dbix_mantis->query( 'SELECT id, name, project_id, user_id as assigned_to_id FROM mantis_category_table' )->hashes;

    my %redmine = map {
        ( $_->{ id } => $_ );
    } $dbix_redmine->query( 'SELECT id, name FROM issue_categories' )->hashes;
    my ( $first_id ) = sort keys %redmine;

    my $mantis_ref = { map {
        ( $_ => [ $mantis{ $_ }->{ name }, { name => 'new', id => -1 } ] )
    } keys %mantis };
    my $redmine_ref = { map {
        ( $_ => $redmine{ $_ } )
    } keys %redmine };
    premap( $mantis_ref, $redmine_ref, 'name' );

    my $default_ref = $first_id
        ? $redmine{ $first_id }
        : { id => -1, name => '*no category found in redmine*' }
    ;

    my $new_ref = create_map( 'Category', $mantis_ref, $redmine_ref, $default_ref, 'id', {
        allow_new     => 1,
        print_mantis  => 1,
        print_redmine => 1
    } );

    return update_maps( $new_ref, \%mantis );
}

=head2 import_users

Maps Mantis users to Redmine users.

User interactive.

=cut

sub import_users {
    my $rx_user = qr/[^a-zA-Z0-9_\-@\.]/;
    my $rx_name = qr/[^\w\s\'\-]/;
    my %mantis = map {
        $_->{ username } =~ s/$rx_user//;
        my ( $firstname, $lastname ) = split( ' ', $_->{ realname } );
        ( $_->{ firstname } = substr( $firstname || $_->{ username }, 0, 30 ) ) =~ s/$rx_name//;
        ( $_->{ lastname }  = substr( $lastname || '', 0, 30 ) ) =~ s/$rx_name//;
        delete $_->{ realname };
        $_->{ email } ||= $_->{ username } . '@dev.null';
        $_->{ mail } = delete $_->{ email };
        $_->{ login } = delete $_->{ username };
        ( $_->{ id } => $_ );
    } $dbix_mantis->query( 'SELECT id, username, realname, email, access_level >= 90 as admin FROM mantis_user_table' )->hashes;

    my %redmine = map {
        ( $_->{ id } => $_ );
    } $dbix_redmine->query( 'SELECT id, login, firstname, lastname, mail FROM users' )->hashes;
    my ( $first_id ) = sort keys %redmine;


    my $mantis_ref = { map {
        ( $_ => [ $mantis{ $_ }->{ login }, { name => 'new', id => -1 } ] )
    } keys %mantis };
    my $redmine_ref = { map {
        ( $_ => { name => $redmine{ $_ }->{ login }, id => $redmine{ $_ }->{ id } } )
    } keys %redmine };
    premap( $mantis_ref, $redmine_ref, 'name' );


    my $default_ref = $first_id
        ? $redmine{ $first_id }
        : {
            id => -1,
            name => '*no user found in redmine*',
            username => '*no user found in redmine*',
            mail => '*',
            login => '*no user found in redmine*',
            firstname => '*no user found in redmine*',
            lastname => '*no user found in redmine*',
        }
    ;

    my $new_ref = create_map( 'User', $mantis_ref, $redmine_ref, $default_ref, 'id', {
        allow_new     => 1,
        print_mantis  => 1,
        print_redmine => 1
    } );

    return update_maps( $new_ref, \%mantis );
}


=head2 perform_import

Perform the whole import.

User interactive.

=cut

sub perform_import {
    my ( $map_ref ) = @_;

    my %report = ();

    print "Import Users\n";
    while( my ( $old_id, $new_ref ) = each %{ $map_ref->{ users } } ) {
        print ".";

        # create new user
        if ( $new_ref->{ id } == -1 ) {
            delete $new_ref->{ id };

            unless ( $DRY ) {
                $dbix_redmine->insert( users => {
                    %$new_ref, # firstname, lastname, login, mail, admin
                    status => 1,
                    type   => 'User',
                } );
                ( $map_ref->{ users }->{ $old_id } ) = $dbix_redmine->query( 'SELECT MAX(id) FROM users' )->list;
            }

            $report{ users_created } ++;
        }

        # use existing
        else {
            $map_ref->{ users }->{ $old_id } = $new_ref->{ id };
            $report{ users_migrated } ++;
        }
    }
    print "OK\n";

    print "Import Projects\n";
    my $count = 1;
    my @mantis_admins = $dbix_mantis->query( 'SELECT id, access_level FROM mantis_user_table WHERE access_level = 90' )->hashes;
    while( my ( $old_id, $new_ref ) = each %{ $map_ref->{ projects } } ) {
        print ".";

        # create new project
        if ( $new_ref->{ id } == -1 ) {
            delete $new_ref->{ id };

            # get max lft/rgt
            my ( $lft, $rgt ) = $dbix_redmine->query( 'SELECT MAX( lft ), MAX(rgt) FROM projects' )->list;
            $lft ||= 0;
            $rgt ||= 0;
            my $max = $lft > $rgt ? $lft : $rgt;
            $max++;

            unless ( $DRY ) {

                $dbix_redmine->insert( projects => {
                    %$new_ref, # name
                    is_public   => 0,
                    created_on  => \'NOW()',
                    updated_on  => \'NOW()',
                    identifier  => 'mantis-'. substr( ''. time(), -5 ) . $count++,
                    status      => 1,
                    lft         => $max,
                    rgt         => $max+1
                } );
                ( $map_ref->{ projects }->{ $old_id } ) = $dbix_redmine->query( 'SELECT MAX(id) FROM projects' )->list;

                $dbix_redmine->insert( enabled_modules => {
                    project_id => $map_ref->{ projects }->{ $old_id },
                    name       => 'issue_tracking'
                } );

                $dbix_redmine->insert( enabled_modules => {
                    project_id => $map_ref->{ projects }->{ $old_id },
                    name       => 'files'
                } );

                $dbix_redmine->insert( enabled_modules => {
                    project_id => $map_ref->{ projects }->{ $old_id },
                    name       => 'calendar'
                } );

                $dbix_redmine->insert( enabled_modules => {
                    project_id => $map_ref->{ projects }->{ $old_id },
                    name       => 'gantt'
                } );

                $dbix_redmine->insert( enabled_modules => {
                    project_id => $map_ref->{ projects }->{ $old_id },
                    name       => 'documents'
                } );

                $dbix_redmine->insert( enabled_modules => {
                    project_id => $map_ref->{ projects }->{ $old_id },
                    name       => 'time_tracking'
                } );

                # activate trackers in projects
                #foreach my $tracker_ref ( $dbix_redmine->query( 'SELECT DISTINCT(id) FROM trackers' )->list ) {
                foreach my $tracker_ref ( 1, 2 ) {
                    $dbix_redmine->insert( projects_trackers => {
                        project_id => $map_ref->{ projects }->{ $old_id },
                        tracker_id => $tracker_ref
                    } );
                }

                # Add admins as manager to all projects
                foreach my $admin_ref ( @mantis_admins ) {
                    $dbix_redmine->insert( members => {
                        project_id => $map_ref->{ projects }->{ $old_id },
                        user_id    => $map_ref->{ users }->{ $admin_ref->{ id } }
                    } );
                    my $member_id = $dbix_redmine->last_insert_id(undef, undef, undef, undef);
                    $dbix_redmine->insert( member_roles => {
                        member_id => $member_id,
                        role_id   => $map_ref->{ roles }->{ $admin_ref->{ access_level } }->{ id }
                    } );
                }
                # insert documents
                if (! $opt{ attachments_in_db } ) {
                my $documents_sql = <<SQLQUERY;
SELECT
    b.diskfile,
    b.filename,
    b.file_type,
    FROM_UNIXTIME( b.date_added, '%Y-%m-%d %T' ) AS `created_on`,
    b.title,
    b.description,
    b.content,
    b.user_id
FROM mantis_project_file_table b
WHERE
    b.project_id = ?
SQLQUERY

                    my $documents = $dbix_mantis->query( $documents_sql, $old_id );
                    while ( my $documents_ref = $documents->hash ) {
                        print "+";

                        unless ( $DRY ) {

                            # write file to disk
                            my $filename = "$documents_ref->{ diskfile }";
                            my $output = "$opt{ attachment_dir }/$filename";
                            open my $fh, '>', $output or die "Cannot open attachment file '$output' for write: $!";
                            binmode $fh;
                            print $fh delete $documents_ref->{ content };
                            close $fh;

                            # insert
                            $dbix_redmine->insert( documents => {
                                project_id     => $map_ref->{ projects }->{ $old_id },
                                category_id    => 7, # we only use tech-docs - user-doc would be 6
                                title          => $documents_ref->{ title },
                                description    => $documents_ref->{ description },
                                created_on     => $documents_ref->{ created_on },
                            } );
                            my $container_id = $dbix_redmine->last_insert_id(undef, undef, undef, undef);
                            $dbix_redmine->insert( attachments => {
                                container_id   => $container_id,
                                container_type => 'Document',
                                filename       => $documents_ref->{ filename },
                                disk_filename  => $filename,
                                filesize       => -s $output,
                                content_type   => $documents_ref->{ file_type },
                                author_id      => $map_ref->{ users }->{ $documents_ref->{ user_id } } || 2,
                                created_on     => $documents_ref->{ created_on },
                                description    => $documents_ref->{ title },
                            } );
                        }
                    }
                } else {
                	# we have the attachments in the db -> exit
                }

            }

            $report{ projects_created } ++;
        }

        # use existing
        else {
            $map_ref->{ projects }->{ $old_id } = $new_ref->{ id };
            $report{ projects_migrated } ++;
        }
    }

    # Add parents (has to be done after all projects have been imported)
    my @child_refs = $dbix_mantis->query( 'SELECT child_id,parent_id FROM mantis_project_hierarchy_table' )->hashes;
    foreach my $child_ref ( @child_refs ) {
        my %parent_id = ( parent_id => $map_ref->{ projects }->{ $child_ref->{ parent_id } } );
        my %child_id = ( id => $map_ref->{ projects }->{ $child_ref->{ child_id } } );
        $dbix_redmine->update( 'projects',
            \%parent_id,
            \%child_id
        );
    }
    print "OK\n";

    print "Import Members\n";

   my $mantis_members = $dbix_mantis->query( <<SQLMEMBERS );
SELECT
    project_id,
    user_id,
    access_level
FROM
    mantis_project_user_list_table
SQLMEMBERS

    while( my $member_ref = $mantis_members->hash ) {
        print ".";

        unless ( $DRY ) {
             $dbix_redmine->insert( members => {
                 project_id => $map_ref->{ projects }->{ $member_ref->{ project_id } },
                 user_id    => $map_ref->{ users }->{ $member_ref->{ user_id } }
             } );
             my $member_id = $dbix_redmine->last_insert_id(undef, undef, undef, undef);
             $dbix_redmine->insert( member_roles => {
                member_id => $member_id,
                role_id   => $map_ref->{ roles }->{ $member_ref->{ access_level } }->{ id }
             } );
        }
        $report{ members_migrated } ++;
    }
    print "OK\n";


    print "Import Versions\n";
    my %version_map = ();
    while( my ( $old_id, $new_ref ) = each %{ $map_ref->{ versions } } ) {
        print ".";

        # create new version
        if ( $new_ref->{ id } == -1 ) {
            delete $new_ref->{ id };
            my $project_id = $map_ref->{ projects }->{ delete $new_ref->{ project_id } };
            my $released   = $new_ref->{ released } ? 'closed' : 'open';

            unless ( $DRY ) {
                $dbix_redmine->insert( versions => {
                    name            => $new_ref->{ name },
                    description     => $new_ref->{ description },
                    project_id      => $project_id,
                    status          => $released,
                    effective_date  => $new_ref->{ effective_date }
                } );
                ( $map_ref->{ versions }->{ $old_id } ) = $dbix_redmine->query( 'SELECT MAX(id) FROM versions' )->list;
                $version_map{ $new_ref->{ name } } = $map_ref->{ versions }->{ $old_id };
            }
            else {
                $version_map{ $new_ref->{ name } } =
                $map_ref->{ versions }->{ $old_id } = 'NEW';
            }

            $report{ versions_created } ++;
        }

        # use existing
        else {
            $version_map{ $new_ref->{ name } } = $map_ref->{ versions }->{ $old_id } = $new_ref->{ id };
            $report{ versions_migrated } ++;
        }
    }
    print "OK\n";

    # use Trackers -> Categories
    if ( $opt{ category_source } eq 'trackers' ) {
        print "Import Trackers\n";
        my @project_ids = $dbix_redmine->query( 'SELECT id FROM projects' )->flat;
        while( my ( $old_id, $new_ref ) = each %{ $map_ref->{ trackers } } ) {
            print ".";

            # create new tracker
            if ( $new_ref->{ id } == -1 ) {
                delete $new_ref->{ id };

                # get tracker probs
                my $name       = delete $new_ref->{ name };
                my $project_id = delete $new_ref->{ project_id };
                my ( $position ) = $dbix_redmine->query( 'SELECT MAX(position)+1 FROM trackers' )->list;

                unless ( $DRY ) {

                    # create tracker
                    $dbix_redmine->insert( trackers => {
                        name          => $name,
                        position      => $position,
                        is_in_roadmap => 0,
                        is_in_chlog   => 0,
                    } );
                    ( $map_ref->{ trackers }->{ $old_id } ) = $dbix_redmine->query( 'SELECT MAX(id) FROM trackers' )->list;

                    # link tracker to project(s)
                    my @insert = $project_id == 0 ? @project_ids : ( $map_ref->{ projects }->{ $project_id } );
                    foreach my $insert( @insert ) {
                        $dbix_redmine->insert( projects_trackers => {
                            project_id => $insert,
                            tracker_id => $map_ref->{ trackers }->{ $old_id }
                        } );
                    }
                }

                $report{ trackers_created } ++;
            }

            # use existing
            else {
                $map_ref->{ trackers }->{ $old_id } = $new_ref->{ id };
                $report{ trackers_migrated } ++;
            }
        }
        print "OK\n";
    }

    # use Categories -> Categories (default)
    else {
        print "Import Categories\n";
        my @project_ids = $dbix_redmine->query( 'SELECT id FROM projects' )->flat;
        my @category_ids = $dbix_redmine->query( 'SELECT id FROM issue_categories' )->flat;
        while( my ( $old_id, $new_ref ) = each %{ $map_ref->{ categories } } ) {
            print ".";

            # create new category
            if ( $new_ref->{ id } == -1 ) {
                delete $new_ref->{ id };

                # get category probs
                my $name       = delete $new_ref->{ name };
                my $user_id    = delete $new_ref->{ assigned_to_id };
                # link category to project
                my $project_id = $map_ref->{ projects }->{ delete $new_ref->{ project_id } } ;

                unless ( $DRY ) {

                    unless ( $project_id == 0 ) {
                        # create category
                        $dbix_redmine->insert( issue_categories => {
                            name           => $name,
                            assigned_to_id => $map_ref->{ users }->{ $user_id },
                            project_id     => $project_id
                        } );
                    }
                    ( $map_ref->{ categories }->{ $old_id } ) = $dbix_redmine->query( 'SELECT MAX(id) FROM issue_categories' )->list;
                }

                $report{ categories_created } ++;
            }

            # use existing
            else {
                $map_ref->{ categories }->{ $old_id } = $new_ref->{ id };
                $report{ categories_migrated } ++;
            }
        }
        print "OK\n";
    }


    # now the hard part .. import all issues!
    print "Import Issues (. = Issue, - = Journal, + = Attachment)\n";
    my $issues = $dbix_mantis->query( <<SQL );
SELECT
    b.id,
    b.project_id,
    b.reporter_id,
    b.handler_id,
    b.priority,
    b.status,
    b.target_version,
    b.fixed_in_version,
    b.severity,
    b.category_id,
    b.summary AS `subject`,
    DATE_FORMAT( FROM_UNIXTIME( b.date_submitted ), '%Y-%m-%d %T' ) AS `created_on`,
    DATE_FORMAT( FROM_UNIXTIME( b.date_submitted ), '%Y-%m-%d' ) AS `start_date`,
    DATE_FORMAT( FROM_UNIXTIME( b.last_updated ), '%Y-%m-%d %T' ) AS `updated_on`,
    CONCAT_WS( "\n\n", tt.description, tt.steps_to_reproduce, tt.additional_information ) AS `description`
FROM mantis_bug_table b
LEFT JOIN mantis_bug_text_table tt ON ( tt.id = b.bug_text_id )
SQL

    my $notes_sql = <<SQLNOTES;
SELECT
    b.reporter_id,
    DATE_FORMAT( FROM_UNIXTIME( b.date_submitted ), '%Y-%m-%d %T' ) AS `created_on`,
    b.time_tracking,
    b.last_modified,
    tt.note
FROM mantis_bugnote_table b
LEFT JOIN mantis_bugnote_text_table tt ON ( tt.id = b.bugnote_text_id )
WHERE
    b.bug_id = ?
SQLNOTES

    my $history_sql = <<SQLNOTES;
SELECT
    b.user_id,
    b.field_name,
    b.old_value,
    b.new_value,
    b.type,
    FROM_UNIXTIME( b.date_modified, '%Y-%m-%d %T' ) AS `created_on`
FROM mantis_bug_history_table b
WHERE
    b.bug_id = ?
SQLNOTES

    my $attachments_sql = <<SQLNOTES;
SELECT
    b.diskfile,
    b.filename,
    b.file_type,
    FROM_UNIXTIME( b.date_added, '%Y-%m-%d %T' ) AS `created_on`,
    CONCAT_WS( "\n", b.title, b.description ) AS `description`,
    b.content,
    b.user_id
FROM mantis_bug_file_table b
WHERE
    b.bug_id = ?
SQLNOTES

    my %issue_map = ();
    while ( my $issue_ref = $issues->hash ) {
        print ".";

        my $issue_id;

        #print "$issue_ref->{ id }: $issue_ref->{ target_version } -> $version_map{ $issue_ref->{ target_version } }\n" if $issue_ref->{ target_version };
        #print "is feature: $issue_ref->{ subject } ( $opt{ tracker_id_feature } )\n" if ($issue_ref->{ severity } == 10);

        my $trackerIdFeature = ($opt{ tracker_id_feature }) ? $opt{ tracker_id_feature } : 2;
        my $trackerIdBug = ($opt{ tracker_id_bug }) ? $opt{ tracker_id_bug } : 1;

        unless ( $DRY ) {
            # insert
            $dbix_redmine->insert( issues => my $ref = {
            	# severity 10 => feature / alle anderen -> bug
                tracker_id       => ($issue_ref->{ severity } == 10) ? $trackerIdFeature : $trackerIdBug,
                project_id       => $map_ref->{ projects }->{ $issue_ref->{ project_id } },
                category_id      => $map_ref->{ categories }->{ $issue_ref->{ category_id } },
                subject          => $issue_ref->{ subject },
                description      => $issue_ref->{ description },
                status_id        => $map_ref->{ stati }->{ $issue_ref->{ status } }->{ id },
                assigned_to_id   => $map_ref->{ users }->{ $issue_ref->{ handler_id } },
                priority_id      => $map_ref->{ priorities }->{ $issue_ref->{ priority } }->{ id },
                author_id        => $map_ref->{ users }->{ $issue_ref->{ reporter_id } } || 2,
                created_on       => $issue_ref->{ created_on },
                updated_on       => $issue_ref->{ updated_on },
                start_date       => $issue_ref->{ start_date },
                done_ratio       => ( $issue_ref->{ status } eq 90 ) || ( $issue_ref->{ status } eq 80 ) ? 100 : 0,
                lft              => 1,
                rgt              => 2,
                fixed_version_id => $issue_ref->{ target_version } && defined $version_map{ $issue_ref->{ target_version } }
                    ? $version_map{ $issue_ref->{ target_version } }
                    : defined $version_map{ $issue_ref->{ fixed_in_version } } ? $version_map{ $issue_ref->{ fixed_in_version } } : 0
            } );

            # get id of the issue
            ( $issue_id ) = $dbix_redmine->query( 'SELECT MAX(id) FROM issues' )->list;
            $issue_map{ $issue_ref->{ id } } = $issue_id;
        }

        $report{ issues_created } ++;

        # insert notes
        my $notes = $dbix_mantis->query( $notes_sql, $issue_ref->{ id } );
        while ( my $note_ref = $notes->hash ) {
            print "-";

            unless ( $DRY ) {

                # insert
                $dbix_redmine->insert( journals => {
                    journalized_id   => $issue_id,
                    journalized_type => 'Issue',
                    user_id          => $map_ref->{ users }->{ $note_ref->{ reporter_id } } || 2,
                    notes            => $note_ref->{ note },
                    created_on       => $note_ref->{ created_on },
                } );
                if ( $note_ref->{ time_tracking } ne 0 ) {
                    $dbix_redmine->insert( time_entries => {
                        project_id   => $map_ref->{ projects }->{ $issue_ref->{ project_id } },
                        user_id      => $map_ref->{ users }->{ $note_ref->{ reporter_id } } || 2,
                        issue_id     => $issue_id,
                        activity_id  => 9, # development
                        spent_on     => $note_ref->{ created_on },
                        created_on   => $note_ref->{ created_on },
                        updated_on   => $note_ref->{ last_modified },
                        # min -> hours (two decimal places are sufficient)
                        #hours        => sprintf("%.2f", $notes_ref->{ time_tracking } / 60 ),
                        hours        => $note_ref->{ time_tracking } / 60,
                    } );
                }
            }

            $report{ journals_created } ++;
        }

        # import issue history
        my @mantis_bug_histories = $dbix_mantis->query( $history_sql, $issue_ref->{ id } )->hashes;

        foreach my $history_ref ( @mantis_bug_histories ) {
            # currently only status changes are imported
            if ( $history_ref->{ field_name } eq 'status' ) {
                print "-";

                unless ( $DRY ) {

                    # insert
                    $dbix_redmine->insert( journals => {
                        journalized_id   => $issue_id,
                        journalized_type => 'Issue',
                        user_id          => $map_ref->{ users }->{ $history_ref->{ user_id } } || 2,
                        created_on       => $history_ref->{ created_on },
                    } );
                    my $journal_id = $dbix_redmine->last_insert_id(undef, undef, undef, undef);
                    $dbix_redmine->insert( journal_details => {
                        journal_id   => $journal_id,
                        property     => 'attr',
                        prop_key     => 'status_id',
                        old_value    => $map_ref->{ stati }->{ $history_ref->{ old_value } }->{ id },
                        value        => $map_ref->{ stati }->{ $history_ref->{ new_value } }->{ id },
                    } );
                    if ( $history_ref->{ new_value } eq 90 ) {
                        my %closed_on = ( closed_on =>  $history_ref->{ created_on } );
                        my %where_issue_id = ( id => $issue_id );
                        $dbix_redmine->update( 'issues',
                            \%closed_on,
                            \%where_issue_id
                        );
                    }

                }

                $report{ journals_created } ++;
            }
        }

        # insert attachments
        if (! $opt{ attachments_in_db } ) {
            my $attachments = $dbix_mantis->query( $attachments_sql, $issue_ref->{ id } );
            while ( my $attachment_ref = $attachments->hash ) {
                # we have the attachments in the db -> exit
                print "+";

                unless ( $DRY ) {

                    # write file to disk
                    my $filename = "$attachment_ref->{ diskfile }";
                    my $output = "$opt{ attachment_dir }/$filename";
                    open my $fh, '>', $output or die "Cannot open attachment file '$output' for write: $!";
                    binmode $fh;
                    print $fh delete $attachment_ref->{ content };
                    close $fh;

                    # insert
                    $dbix_redmine->insert( attachments => {
                        container_id   => $issue_id,
                        container_type => 'Issue',
                        filename       => $attachment_ref->{ filename },
                        disk_filename  => $filename,
                        filesize       => -s $output,
                        content_type   => $attachment_ref->{ file_type },
                        description    => $attachment_ref->{ description },
                        created_on     => $attachment_ref->{ created_on },
                        author_id      => $map_ref->{ users }->{ $attachment_ref->{ user_id } } || 2,
                    } );
                }
                $report{ attachments_created } ++;
            }
        } else {
        	# we have the attachments in the db -> exit
        }
    }

    unless ( $DRY ) {
        # set root_id to id for redmine to work properly
        $dbix_redmine->query( 'UPDATE issues SET root_id=id WHERE root_id IS NULL;' );
    }

    print "OK\n";

    print "Import Relations\n";
    my $relations = $dbix_mantis->query( <<SQLRELATIONS );
SELECT
    source_bug_id,
    destination_bug_id,
    relationship_type
FROM
    mantis_bug_relationship_table
SQLRELATIONS

    while( my $relation_ref = $relations->hash ) {
        print ".";

        unless ( $DRY ) {
            $dbix_redmine->insert( issue_relations => {
                issue_from_id => $issue_map{ $relation_ref->{ source_bug_id } },
                issue_to_id   => $issue_map{ $relation_ref->{ destination_bug_id } },
                relation_type => $map_ref->{ relations }->{ $relation_ref->{ relationship_type } }
            } );
        }
        $report{ relations_created } ++;
    }
    print "OK\n";

    print "Import Custom Fields (. = Definition, - = Project relation, + = Issue value)\n";
    my $custom_fields = $dbix_mantis->query( <<SQLRELATIONS );
SELECT
    id,
    name,
    possible_values,
    length_min,
    length_max,
    valid_regexp,
    type,
    require_report
FROM
    mantis_custom_field_table
SQLRELATIONS

    my @tracker_ids = $dbix_redmine->query( 'SELECT id FROM trackers' )->flat;
    while( my $custom_field_ref = $custom_fields->hash ) {
        print ".";
        unless ( $DRY ) {
            my @possible_values = split( /\s*\|\s*/, $custom_field_ref->{ possible_values } );
            my $field_format    = $custom_field_ref->{ type } == 5 && scalar @possible_values > 1
                ? 'list'
                : $map_ref->{ custom_fields }->{ $custom_field_ref->{ type } }
            ;

            my $ref = {
                name            => substr( $custom_field_ref->{ name }, 0, 30 ),
                field_format    => $field_format,
                min_length      => $custom_field_ref->{ length_min },
                max_length      => $custom_field_ref->{ length_max },
                regexp          => $custom_field_ref->{ valid_regexp } || '',
                possible_values => YAML::Dump( \@possible_values ),
                is_required     => $custom_field_ref->{ require_report },
                type            => 'IssueCustomField'
            };
            #$dbix_redmine->insert( custom_fields => $ref );
            #print Dumper $ref;

            # there is some issue with multiline .. hmm.. stragen enough:
            my $sql = 'INSERT INTO custom_fields ('. join( ', ', map { "`$_`" } sort keys %$ref ). ') VALUES ('. join( ', ', map { "?" } sort keys %$ref ). ')';
            my @sql_values = map { $ref->{ $_ } } sort keys %$ref;
            #print "$sql : ". join( ", ", @sql_values ). "\n";
            $dbix_redmine->query( $sql, @sql_values );

            my ( $custom_field_id ) = $dbix_redmine->query( 'SELECT MAX(id) FROM custom_fields' )->list;

            # associate with all trackers
            $dbix_redmine->insert( custom_fields_trackers => {
                custom_field_id => $custom_field_id,
                tracker_id      => $_
            } ) for @tracker_ids;

            # get projects and re-associate fields
            my @assoc_project_ids = $dbix_mantis->query( 'SELECT project_id FROM mantis_custom_field_project_table WHERE field_id = ?', $custom_field_ref->{ id } )->flat;
            #die Dumper { assoc => \@assoc_project_ids, projects => $map_ref->{ projects } };
            foreach my $pid( @assoc_project_ids ) {
                print "-";
                $dbix_redmine->insert( custom_fields_projects => {
                    custom_field_id => $custom_field_id,
                    project_id      => $map_ref->{ projects }->{ $pid }
                } );
            }


            # set all custom field values to issues
            my $custom_field_values = $dbix_mantis->query( 'SELECT bug_id, value FROM mantis_custom_field_string_table WHERE field_id = ?', $custom_field_ref->{ id } );
            while( my $field_value_ref = $custom_field_values->hash ) {
                print "+";
                $dbix_redmine->insert( custom_values => {
                    customized_type => 'Issue',
                    customized_id   => $issue_map{ $field_value_ref->{ bug_id } },
                    custom_field_id => $custom_field_id,
                    value           => $field_value_ref->{ value }
                } );
            }
        }

        $report{ custom_fields_created } ++;
    }
    print "OK\n";

    print "\n\nAll Done\n";
    printf "%-40s : %5d / %5d\n", 'Users (migrated/created)', $report{ users_migrated } || 0, $report{ users_created } || 0;
    printf "%-40s : %5d / %5d\n", 'Projects (migrated/created)', $report{ projects_migrated } || 0, $report{ projects_created } || 0;
    printf "%-40s : %5d / %5d\n", 'Versions (migrated/created)', $report{ versions_migrated } || 0, $report{ versions_created } || 0;
    printf "%-40s : %5d / %5d\n", 'Trackers (migrated/created)', $report{ trackers_migrated } || 0, $report{ trackers_created } || 0;
    printf "%-40s : %5d / %5d\n", 'Categories (migrated/created)', $report{ categories_migrated } || 0, $report{ categories_created } || 0;
    printf "%-40s : %5d\n", 'Members imported', $report{ members_migrated } || 0;
    printf "%-40s : %5d\n", 'Issues imported', $report{ issues_created } || 0;
    printf "%-40s : %5d\n", 'Journals imported', $report{ journals_created } || 0;
    printf "%-40s : %5d\n", 'Attachments imported', $report{ attachments_created } || 0;
    printf "%-40s : %5d\n", 'Relations imported', $report{ relations_created } || 0;
    printf "%-40s : %5d\n", 'Custom Fields imported', $report{ custom_fields_created } || 0;
    print "\n";
    if ( $DRY ) {
        print "** NOTHING PERFORMED, JUST A DRY RUN! **\n";
    }
    else {
        print "** Import completed, have fun! **\n";
        print "You should copy now all extracted files from '$opt{ attachment_dir }/' to your attachment directory of redmine (usually '/files' in your redmine install dir)\n";
        print "You have to REBUILD THE PROJECT TREE\nby running the 2 following commands from the rails console (`ruby script/rails c production`):\n    Project.update_all :lft => nil, :rgt => nil\n    Project.rebuild!(false)\n"
    }

}






=head1 PRIVATE METHODS


=head2 update_maps

Update mappings after create_maps call

=cut

sub update_maps {
    my ( $new_ref, $mantis_ref ) = @_;
    foreach my $id( keys %$new_ref ) {
        $new_ref->{ $id } = $new_ref->{ $id }->{ id } == -1
            ? { %{ $mantis_ref->{ $id } }, id => -1 }
            : { %{ $mantis_ref->{ $id } }, id => $new_ref->{ $id }->{ id } }
        ;
    }
    return $new_ref;
}


=head2 premap

Build premap by trying to find corresponding object in the Redmine database

=cut

sub premap {
    my ( $mantis_ref, $redmine_ref, $key ) = @_;
    foreach my $mantis( keys %$mantis_ref ) {
        my $search = lc( $mantis_ref->{ $mantis }->[0] );
        while( my ( $redmine, $ref ) = each %$redmine_ref ) {
            if ( $search eq lc( $ref->{ $key } ) ) {
                $mantis_ref->{ $mantis }->[1] = $ref;
                last;
            }
        }
    }
}


=head2 create_map

Create mappings with user interactive input from Mantis objects to Redmine objects.

=cut

sub create_map {
    my ( $name, $mantis_ref, $redmine_ref, $default_ref, $key, $args_ref ) = @_;
    $args_ref ||= {
        allow_new     => 0,
        print_mantis  => 0,
        print_redmine => 0
    };


    my $legend_sub = sub {
        print "Mantis: $name\n";
        foreach my $position( sort keys %$mantis_ref ) {
            printf "  %-20s : %3d\n", $mantis_ref->{ $position }->[0], $position;
        }
        print "\n";
        print "Redmine: $name\n";
        foreach my $position( sort keys %$redmine_ref ) {
            printf "  %-20s : %3d\n", $redmine_ref->{ $position }->{ name }, $position;
        }
        print "\n";
    };

    my $translation_sub = sub {
        print "$name translation\n";
        printf "    %-20s ->     %-20s\n", "Mantis", "Redmine";
        foreach my $position( sort keys %$mantis_ref ) {
            printf "%3d:%-20s -> %3d:%-20s\n",
                $position, $mantis_ref->{ $position }->[0],
                $mantis_ref->{ $position }->[1]->{ $key }, $mantis_ref->{ $position }->[1]->{ name }
            ;
        }
        print "\n";
    };
    $legend_sub->();
    $translation_sub->();
    my ( $last_mantis ) = ( reverse sort keys %$mantis_ref );

    my @request = ();
    my $request_new = $args_ref->{ allow_new } ? " or num:-1 for create as new " : "";
    push @request,"Type 'ok' if you confirm or num:num ${request_new}to change assignment";

    my $myname = $default_ref->{ name } || $default_ref->{ login };
    push @request,"  eg $last_mantis:$default_ref->{ $key } to change $name of '$mantis_ref->{ $last_mantis }->[0]' to '$myname'";
    push @request, "  type 'print' to show the Redmine/Mantis tabels again";
    push @request, "(ok/num:num/print)";
    my $request = join( "\n", @request );

    my $read = read_in( $request );
    while ( lc( $read ) ne 'ok' ) {
        if ( $read =~ /^(\d+):(\d+)$/ ) {
            my ( $mantis, $redmine ) = ( $1, $2 );
            if ( defined $mantis_ref->{ $mantis } && defined $redmine_ref->{ $redmine } ) {
                $mantis_ref->{ $mantis }->[1] = $redmine_ref->{ $redmine };
                $translation_sub->();
            }
            else {
                err( "Mantis $name '$mantis' not defined" ) unless defined $mantis_ref->{ $mantis };
                err( "Redmine $name '$redmine' not defined" ) unless defined $redmine_ref->{ $redmine };
            }
        }
        elsif ( $args_ref->{ allow_new } && $read =~ /^(\d+):-1$/ ) {
            my $mantis = $1;
            if ( defined $mantis_ref->{ $mantis } ) {
                $mantis_ref->{ $mantis }->[1] = { name => 'new', $key => -1 };
                $translation_sub->();
            }
            else {
                err( "Mantis $name '$mantis' not defined" );
            }
        }
        elsif ( $read eq 'print' ) {
            $legend_sub->();
        }
        $read = read_in( $request );
    }

    # return map of ( number => id )
    return { map {
        ( $_ => $mantis_ref->{ $_ }->[1] );
    } keys %$mantis_ref };
}


=head2 err

Error output

=cut

sub err {
    my ( $msg ) = @_;
    print "** $msg **\n";
}


=head2 read_in

Print input instructions and read from STDIN

=cut

sub read_in {
    my ( $request ) = @_;
    print "$request > ";
    my $in = <STDIN>;
    chomp $in;
    return $in;
}


=head2 read_config

Read config file and return as hash

=cut

sub read_config {
    my $file = shift;
    open my $fh, '<', $file or die "Cannot open '$file' for read: $!";
    my %conf = map {
        chomp; s/^\s+//; s/\s+$//;
        split( /\s*=\s*/, $_, 2 );
    } grep {
        /\w.*?=/
    } <$fh>;
    close $fh;
    return %conf;
}


=head2 save_map

Save user provided mapping to storage file "store-<name>.map" in YAML format

=cut

sub save_map {
    my ( $name, $map_ref ) = @_;
    return YAML::DumpFile( "store-$name.map", $map_ref );
}


=head2 load_map

Load YAML map from disk

=cut

sub load_map {
    my ( $name ) = @_;
    return YAML::LoadFile( "store-$name.map" );
}

