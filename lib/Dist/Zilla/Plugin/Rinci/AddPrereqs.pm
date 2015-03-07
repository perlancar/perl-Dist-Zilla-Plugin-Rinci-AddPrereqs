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
);

use Perinci::Sub::Normalize qw(normalize_function_metadata);

sub munge_files {
    my $self = shift;

    $self->munge_file($_) for @{ $self->found_files };
    return;
}

sub _add_prereq {
    my ($self, $mod, $ver) = @_;
    $self->log_debug("Adding prereq: $mod => $ver");
    $self->zilla->register_prereqs({phase=>'runtime'}, $mod, $ver);
}

sub _add_prereqs_from_func_meta {
    my ($self, $meta) = @_;

    $meta = normalize_function_metadata($meta);

    # from deps, XXX support digging into 'any' and 'all'
    if (my $deps = $meta->{deps}) {
        $self->zilla->register_prereqs(
            {phase=>'runtime'}, "Perinci::Sub::DepChecker"=>0);
        for (keys %$deps) {
            # skip builtin deps supported by Perinci::Sub::DepChecker
            next if /\A(any|all|none|env|code|prog|pkg|func|exec|
                         tmp_dir|trash_dir|undo_trash_dir)\z/x;
            $self->_add_prereq("Perinci::Sub::Dep::$_"=>0);
        }
    }

    {
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
        }
    }
}

sub munge_file {
    no strict 'refs';

    my ($self, $file) = @_;

    local @INC = ('lib', @INC);

    if (my ($pkg_pm, $pkg) = $file->name =~ m!^lib/((.+)\.pm)$!) {
        $pkg =~ s!/!::!g;
        require $pkg_pm;
        my $spec = \%{"$pkg\::SPEC"};
        for my $func (grep {/\A\w+\z/} sort keys %$spec) {
            $self->_add_prereqs_from_func_meta($spec->{$func});
        }
    } else {
        # XXX script currently not yet supported
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

This plugin will add prereqs for the following:

=over

=item *

For every dependency mentioned in C<deps> property in function metadata, will
add a prereq to C<Perinci::Sub::Dep::NAME>.

=item *

For every entity mentioned in C<x.schema.entity> or C<x.schema.element_entity>
in function metadata, will add a prereq to C<Perinci::Sub::ArgEntity::NAME>.

=back


=head1 SEE ALSO

L<Rinci>
