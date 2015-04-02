package Dist::Zilla::Plugin::Rinci::AddPrereqs;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Moose;
with (
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':InstallModules', ':ExecFiles'],
    },
    'Dist::Zilla::Role::DumpPerinciCmdLineScript',
);

use Perinci::Access;
use Perinci::Sub::Normalize qw(normalize_function_metadata);

sub munge_files {
    my $self = shift;

    # roughly list all packages in this dist, from the filenames. XXX does dzil
    # already provide this?
    my %pkgs;
    for (@{ $self->found_files }) {
        next unless $_->name =~ m!\Alib/(.+)\.pm\z!;
        my $pkg = $1; $pkg =~ s!/!::!g;
        $pkgs{$pkg} = $_->name;
    }
    $self->{_packages} = \%pkgs;

    $self->{_added_prereqs} = {};

    $self->munge_file($_) for @{ $self->found_files };
    return;
}

sub _add_prereq {
    my ($self, $mod, $ver) = @_;
    return if defined($self->{_added_prereqs}{$mod}) &&
        $self->{_added_prereqs}{$mod} >= $ver;
    $self->log("Adding prereq: $mod => $ver");
    $self->zilla->register_prereqs({phase=>'runtime'}, $mod, $ver);
    $self->{_added_prereqs}{$mod} = $ver;
}

sub _add_prereqs_from_func_meta {
    my ($self, $meta, $is_cli) = @_;

    $meta = normalize_function_metadata($meta);

    # from deps, XXX support digging into 'any' and 'all'
    if (my $deps = $meta->{deps}) {
        $self->_add_prereq("Perinci::Sub::DepChecker"=>0);
        for (keys %$deps) {
            # skip builtin deps supported by Perinci::Sub::DepChecker
            next if /\A(any|all|none|env|code|prog|pkg|func|exec|
                         tmp_dir|trash_dir|undo_trash_dir)\z/x;
            $self->_add_prereq("Perinci::Sub::Dep::$_"=>0);
        }
    }

    # from x.schema.{entity,element_entity} & x.completion (cli script only)
    {
        last unless $is_cli;
        my $args = $meta->{args};
        last unless $args;
        for my $arg_name (keys %$args) {
            my $arg_spec = $args->{$arg_name};
            my $e;
            $e = $arg_spec->{'x.schema.entity'};
            if ($e) {
                $self->_add_prereq("Perinci::Sub::ArgEntity::$e"=>0);
            }
            $e = $arg_spec->{'x.schema.element_entity'};
            if ($e) {
                $self->_add_prereq("Perinci::Sub::ArgEntity::$e"=>0);
            }
            $e = $arg_spec->{'x.completion'};
            die "x.completion must be an array" unless ref($e) eq 'ARRAY';
            if ($e) {
                $self->_add_prereq("Perinci::Sub::XCompletion::$e->[0]"=>0);
            }
            $e = $arg_spec->{'x.element_completion'};
            die "x.element_completion must be an array" unless ref($e) eq 'ARRAY';
            if ($e) {
                $self->_add_prereq("Perinci::Sub::XCompletion::$e->[0]"=>0);
            }
        }
    }

}

sub munge_file {
    no strict 'refs';

    my ($self, $file) = @_;

    state $pa = Perinci::Access->new;

    local @INC = ('lib', @INC);

    if (my ($pkg_pm, $pkg) = $file->name =~ m!^lib/((.+)\.pm)$!) {
        $pkg =~ s!/!::!g;
        require $pkg_pm;
        my $spec = \%{"$pkg\::SPEC"};
        $self->log_debug(["Found module with non-empty %%SPEC: %s (%s)", $file->name, $pkg])
            if keys %$spec;
        for my $func (grep {/\A\w+\z/} sort keys %$spec) {
            $self->_add_prereqs_from_func_meta($spec->{$func}, 0);
        }
    } else {
        my $res = $self->dump_perinci_cmdline_script($file);
        if ($res->[0] == 412) {
            $self->log_debug(["Skipped %s: %s",
                              $file->name, $res->[1]]);
            return;
        }
        $self->log_fatal(["Can't dump Perinci::CmdLine script '%s': %s - %s",
                          $file->name, $res->[0], $res->[1]]) unless $res->[0] == 200;
        my $cli = $res->[2];

        $self->log_debug(["Found Perinci::CmdLine-based script: %s", $file->name]);

        my @urls;
        push @urls, $cli->{url};
        if ($cli->{subcommands} && ref($cli->{subcommands}) eq 'HASH') {
            push @urls, $_->{url} for values %{ $cli->{subcommands} };
        }
        my %seen_urls;
        for my $url (@urls) {
            next unless defined $url;
            next if $seen_urls{$url}++;

            # only inspect local function Riap URL
            next unless $url =~ m!\A(?:pl:)?/(.+)/[^/]+\z!;

            # add prereq to package, unless it's from our own dist
            my $pkg = $1; $pkg =~ s!/!::!g;
            next if $pkg eq 'main';

            $self->_add_prereq($pkg => 0) unless $self->{_packages}{$pkg};

            # get its metadata
            $self->log_debug(["Performing Riap request: meta => %s", $url]);
            my $res = $pa->request(meta => $url);
            $self->log_fatal(["Can't meta %s: %s-%s", $url, $res->[0], $res->[1]])
                unless $res->[0] == 200;
            my $meta = $res->[2];
            $self->_add_prereqs_from_func_meta($meta, 1);
        }
    }
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Add prerequisites from Rinci metadata

=for Pod::Coverage .+

=head1 SYNOPSIS

In C<dist.ini>:

 [Rinci::AddPrereqs]


=head1 DESCRIPTION

This plugin will search Rinci metadata in all modules and add prereqs for the
following:

=over

=item *

For every dependency mentioned in C<deps> property in function metadata, will
add a prereq to C<Perinci::Sub::Dep::NAME>.

=back

This plugin will also search all Perinci::CmdLine-based scripts, request
metadata from all local Riap URI's used by the scripts, and add prereqs for the
above plus:

=over

=item *

Add prereq for the module specified in the Riap URL. So for example if script
refers to C</Perinci/Examples/some_func>, then a prerequisite will be added for
C<Perinci::Examples> (unless it's from the same distribution).

=item *

For every entity mentioned in C<x.schema.entity> or C<x.schema.element_entity>
in function metadata, will add a prereq to C<Perinci::Sub::ArgEntity::NAME>.

=item *

For every completion mentioned in C<x.completion> or C<x.element_completion> in
function metadata (which have the value of C<[NAME, ARGS]>), will add a prereq
to corresponding C<Perinci::Sub::XCompletion::NAME>.

=back


=head1 SEE ALSO

L<Rinci>
