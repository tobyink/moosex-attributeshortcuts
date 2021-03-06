package MooseX::AttributeShortcuts;

# ABSTRACT: Shorthand for common attribute options

use strict;
use warnings;

use namespace::autoclean;

use Moose ();
use Moose::Exporter;
use Moose::Util::MetaRole;

# debug...
#use Smart::Comments;

{
    package MooseX::AttributeShortcuts::Trait::Attribute;
    use namespace::autoclean;
    use MooseX::Role::Parameterized;

    use MooseX::Types::Moose          ':all';
    use MooseX::Types::Common::String ':all';

    parameter writer_prefix  => (isa => NonEmptySimpleStr, default => '_set_');
    parameter builder_prefix => (isa => NonEmptySimpleStr, default => '_build_');

    # I'm not going to document the following for the moment, as I'm not sure I
    # want to do it this way.
    parameter prefixes => (
        isa     => HashRef[NonEmptySimpleStr],
        default => sub { { } },
    );
    
    my $TC_COUNTER  = 0;
    my $TC_TEMPLATE = 'MooseX::AttributeShortcuts::Types::__ANON__::%04d';

    # Utility function:
    # Wrap a sub to ensure $_ is an alias for $_[0]
    my $_wrap_sub = sub {
        my $sub = shift;
        return sub { local $_ = $_[0]; $sub->(@_) }
    };
    
    # Utility function:
    # Create a Moose::Meta::TypeCoercion from a CODE|HASH|ARRAY ref
    my $_mk_coerce = sub {
        my ($c, $constraint) = @_;
        
        my @map;
        if (ref $c eq 'CODE') {
            @map = (Any => $c);
        }
        elsif (ref $c eq 'ARRAY') {
            my $idx;
            @map = map { ($idx++%2) ? $_wrap_sub->($_) : $_ } @$c;
        }
        elsif (ref $c eq 'HASH') {
            # sort is a fairly arbitrary order, but at least it's
            # consistent. ARRAY is better.
            for my $k (sort keys %$c) {
                push @map, $k => $_wrap_sub->( $c->{$k} );
            }
        }
        
        return unless @map;
        
        my $return = Moose::Meta::TypeCoercion->new(type_constraint => $constraint);
        $return->add_type_coercions(@map);
        return $return;
    };


    role {
        my $p = shift @_;

        my $wprefix = $p->writer_prefix;
        my $bprefix = $p->builder_prefix;
        my %prefix = (
            predicate => 'has',
            clearer   => 'clear',
            trigger   => '_trigger_',
            %{ $p->prefixes },
        );

        has anon_builder => (
            reader    => 'anon_builder',
            writer    => '_set_anon_builder',
            isa       => 'CodeRef',
            predicate => 'has_anon_builder',
            init_arg  => '_anon_builder',
        );
        
        my $_process_options = sub {
            my ($class, $name, $options) = @_;

            my $_has = sub { defined $options->{$_[0]} };
            my $_opt = sub { $_has->(@_) ? $options->{$_[0]} : q{} };

            if ($options->{is}) {

                if ($options->{is} eq 'rwp') {

                    $options->{is}     = 'ro';
                    $options->{writer} = "$wprefix$name";
                }

                if ($options->{is} eq 'lazy') {

                    $options->{is}       = 'ro';
                    $options->{lazy}     = 1;
                    $options->{builder}  = 1
                        unless $_has->('builder') || $_has->('default');
                }
            }

            if ($options->{lazy_build} && $options->{lazy_build} eq 'private') {

                $options->{lazy_build} = 1;
                $options->{clearer}    = "_clear_$name";
                $options->{predicate}  = "_has_$name";
            }

            my $is_private = sub { $name =~ /^_/ ? $_[0] : $_[1] };
            my $default_for = sub {
                my ($opt) = @_;

                return unless $_has->($opt);
                my $opt_val = $_opt->($opt);

                my ($head, $mid)
                    = $opt_val eq '1'  ? ($is_private->('_', q{}), $is_private->(q{}, '_'))
                    : $opt_val eq '-1' ? ($is_private->(q{}, '_'), $is_private->(q{}, '_'))
                    :                    return;

                $options->{$opt} = $head . $prefix{$opt} . $mid . $name;
                return;
            };

            # XXX install builder here if a coderef
            if (defined $options->{builder}) {

                #if (ref $_opt->('builder') eq 'CODE') {
                if ((ref $options->{builder} || q{}) eq 'CODE') {

                    $options->{_anon_builder} = $options->{builder};
                    $options->{builder}       = 1;
                }

                $options->{builder} = "$bprefix$name"
                    if $options->{builder} eq '1';
            }
            ### set our other defaults, if requested...
            $default_for->($_) for qw{ predicate clearer };
            my $trigger = "$prefix{trigger}$name";
            $options->{trigger} = sub { shift->$trigger(@_) }
                if $options->{trigger} && $options->{trigger} eq '1';

            # Type constraint stuff
            if ((ref $options->{isa}    || q{}) eq 'CODE'
            or  (ref $options->{coerce} || q{}) =~ m'^(CODE|HASH|ARRAY)$') {
                
                if ((ref $options->{isa} || q{}) eq 'CODE') {
                    $options->{isa} = Moose::Meta::TypeConstraint->new(
                        name       => sprintf($TC_TEMPLATE, ++$TC_COUNTER),
                        constraint => $_wrap_sub->( $options->{isa} ),
                    );
                    if ($options->{coerce}
                    and (ref $options->{coerce} || q{}) !~ m'^(CODE|HASH|ARRAY)$') {
                        confess "cannot use isa=>CODE and coerce=>1";
                    }
                }
                else {
                    my $FTC = \&Moose::Util::TypeConstraints::find_type_constraint;
                    $options->{isa} = Moose::Meta::TypeConstraint->new(
                        name       => sprintf($TC_TEMPLATE, ++$TC_COUNTER),
                        parent     => $FTC->($options->{isa}) || $FTC->('Item'),
                    );
                }
                
                if ($options->{coerce}) {
                    my $coerce = $_mk_coerce->($options->{coerce}, $options->{isa});
                    if ($coerce) {
                        $options->{isa}->coercion($coerce);
                        $options->{coerce} = 1;
                    }
                    else {
                        confess "error building coercion";
                    }
                }
            }

            return;
        };

        # here we wrap _process_options() instead of the newer _process_is_option(),
        # as that makes our life easier from a 1.x/2.x compatibility
        # perspective -- and that we're potentially altering more than just
        # the 'is' option at one time.

        before _process_options => $_process_options;

        # this feels... bad.  But I'm not sure there's any way to ensure we
        # process options on a clone/extends without wrapping new().

        around new => sub {
            my ($orig, $self) = (shift, shift);
            my ($name, %options) = @_;

            $self->$_process_options($name, \%options)
                if $options{__hack_no_process_options};

            return $self->$orig($name, %options);
        };


        # we hijack attach_to_class in order to install our anon_builder, if
        # we have one.  Note that we don't go the normal
        # associate_method/install_accessor/etc route as this is kinda...
        # different.

        after attach_to_class => sub {
            my ($self, $class) = @_;

            return unless $self->has_anon_builder;

            $class->add_method($self->builder => $self->anon_builder);
            return;
        };
    };
}

my ($import, $unimport, $init_meta) = Moose::Exporter->build_import_methods(
    install => [ 'unimport' ],
    trait_aliases => [
        [ 'MooseX::AttributeShortcuts::Trait::Attribute' => 'Shortcuts' ],
    ],
);

my $role_params;

sub import {
    my ($class, %args) = @_;

    $role_params = {};
    do { $role_params->{$_} = delete $args{"-$_"} if exists $args{"-$_"} }
        for qw{ writer_prefix builder_prefix prefixes };

    @_ = ($class, %args);
    goto &$import;
}

sub init_meta {
    my ($class_name, %args) = @_;
    my $params = delete $args{role_params} || $role_params || undef;
    undef $role_params;

    # Just in case we do ever start to get an $init_meta from ME
    $init_meta->($class_name, %args)
        if $init_meta;

    # make sure we have a metaclass instance kicking around
    my $for_class = $args{for_class};
    die "Class $for_class has no metaclass!"
        unless Class::MOP::class_of($for_class);

    # If we're given paramaters to pass on to construct a role with, we build
    # it out here rather than pass them on and allowing apply_metaroles() to
    # handle it, as there are Very Loud Warnings about how paramatized roles
    # are non-cachable when generated on the fly.

    ### $params
    my $role
        = ($params && scalar keys %$params)
        ? MooseX::AttributeShortcuts::Trait::Attribute
            ->meta
            ->generate_role(parameters => $params)
        : 'MooseX::AttributeShortcuts::Trait::Attribute'
        ;

    Moose::Util::MetaRole::apply_metaroles(
        for             => $for_class,
        class_metaroles => { attribute         => [ $role ] },
        role_metaroles  => { applied_attribute => [ $role ] },
    );

    return Class::MOP::class_of($for_class);
}

1;

__END__

=head1 SYNOPSIS

    package Some::Class;

    use Moose;
    use MooseX::AttributeShortcuts;

    # same as:
    #   is => 'ro', lazy => 1, builder => '_build_foo'
    has foo => (is => 'lazy');

    # same as: is => 'ro', writer => '_set_foo'
    has foo => (is => 'rwp');

    # same as: is => 'ro', builder => '_build_bar'
    has bar => (is => 'ro', builder => 1);

    # same as: is => 'ro', clearer => 'clear_bar'
    has bar => (is => 'ro', clearer => 1);

    # same as: is => 'ro', predicate => 'has_bar'
    has bar => (is => 'ro', predicate => 1);

    # works as you'd expect for "private": predicate => '_has_bar'
    has _bar => (is => 'ro', predicate => 1);

    # extending? Use the "Shortcuts" trait alias
    extends 'Some::OtherClass';
    has '+bar' => (traits => [Shortcuts], builder => 1, ...);

    # or...
    package Some::Other::Class;

    use Moose;
    use MooseX::AttributeShortcuts -writer_prefix => '_';

    # same as: is => 'ro', writer => '_foo'
    has foo => (is => 'rwp');

=head1 DESCRIPTION

Ever find yourself repeatedly specifying writers and builders, because there's
no good shortcut to specifying them?  Sometimes you want an attribute to have
a read-only public interface, but a private writer.  And wouldn't it be easier
to just say "builder => 1" and have the attribute construct the canonical
"_build_$name" builder name for you?

This package causes an attribute trait to be applied to all attributes defined
to the using class.  This trait extends the attribute option processing to
handle the above variations.

=head1 USAGE

This package automatically applies an attribute metaclass trait.  Unless you
want to change the defaults, you can ignore the talk about "prefixes" below.

=head1 EXTENDING A CLASS

If you're extending a class and trying to extend its attributes as well,
you'll find out that the trait is only applied to attributes defined locally
in the class.  This package exports a trait shortcut function "Shortcuts" that
will help you apply this to the extended attribute:

    has '+something' => (traits => [Shortcuts], ...);

=head1 PREFIXES

We accept two parameters on the use of this module; they impact how builders
and writers are named.

=head2 -writer_prefix

    use MooseX::::AttributeShortcuts -writer_prefix => 'prefix';

The default writer prefix is '_set_'.  If you'd prefer it to be something
else (say, '_'), this is where you'd do that.

=head2 -builder_prefix

    use MooseX::::AttributeShortcuts -builder_prefix => 'prefix';

The default builder prefix is '_build_', as this is what lazy_build does, and
what people in general recognize as build methods.

=head1 NEW ATTRIBUTE OPTIONS

Unless specified here, all options defined by L<Moose::Meta::Attribute> and
L<Class::MOP::Attribute> remain unchanged.

Want to see additional options?  Ask, or better yet, fork on GitHub and send
a pull request. If the shortcuts you're asking for already exist in L<Moo> or
L<Mouse> or elsewhere, please note that as it will carry significant weight.

For the following, "$name" should be read as the attribute name; and the
various prefixes should be read using the defaults.

=head2 is => 'rwp'

Specifying C<is =E<gt> 'rwp'> will cause the following options to be set:

    is     => 'ro'
    writer => "_set_$name"

=head2 is => 'lazy'

Specifying C<is =E<gt> 'lazy'> will cause the following options to be set:

    is       => 'ro'
    builder  => "_build_$name"
    lazy     => 1

B<NOTE:> Since 0.009 we no longer set C<init_arg =E<gt> undef> if no C<init_arg>
is explicitly provided.  This is a change made in parallel with L<Moo>, based
on a large number of people surprised that lazy also made one's C<init_def>
undefined.

=head2 is => 'lazy', default => ...

Specifying C<is =E<gt> 'lazy'> and a default will cause the following options to be
set:

    is       => 'ro'
    lazy     => 1
    default  => ... # as provided

That is, if you specify C<is =E<gt> 'lazy'> and also provide a C<default>, then
we won't try to set a builder, as well.

=head2 builder => 1

Specifying C<builder =E<gt> 1> will cause the following options to be set:

    builder => "_build_$name"

=head2 clearer => 1

Specifying C<clearer =E<gt> 1> will cause the following options to be set:

    clearer => "clear_$name"

or, if your attribute name begins with an underscore:

    clearer => "_clear$name"

(that is, an attribute named "_foo" would get "_clear_foo")

=head2 predicate => 1

Specifying C<predicate =E<gt> 1> will cause the following options to be set:

    predicate => "has_$name"

or, if your attribute name begins with an underscore:

    predicate => "_has$name"

(that is, an attribute named "_foo" would get "_has_foo")

=head2 trigger => 1

Specifying C<trigger =E<gt> 1> will cause the attribute to be created with a trigger
that calls a named method in the class with the options passed to the trigger.
By default, the method name the trigger calls is the name of the attribute
prefixed with "_trigger_".

e.g., for an attribute named "foo" this would be equivalent to:

    trigger => sub { shift->_trigger_foo(@_) }

For an attribute named "_foo":

    trigger => sub { shift->_trigger__foo(@_) }

This naming scheme, in which the trigger is always private, is the same as the
builder naming scheme (just with a different prefix).

=head2 builder => sub { ... }

Passing a coderef to builder will cause that coderef to be installed in the
class this attribute is associated with the name you'd expect, and
C<builder =E<gt> 1> to be set.

e.g., in your class,

    has foo => (is => 'ro', builder => sub { 'bar!' });

...is effectively the same as...

    has foo => (is => 'ro', builder => '_build_foo');
    sub _build_foo { 'bar!' }

=head2 isa => sub { ... }

Passing a coderef as a type constraint creates and uses an anonymous type
contraint. Within the coderef, the variable C<< $_ >> may be used to refer to
the value being tested.

Note that with an anonymous type constraint such as this, you may not use
C<< coerce => 1 >>, however you may use either of the coercion shortcuts
documented below.

=head2 coerce => sub { ... }

Coerces to the given type (from Any) using a custom coercion function.

    has num => (
        is      => 'ro',
        isa     => 'Num',           # or a MooseX::Types type
        coerce  => sub { $_ + 0 },  # coerce from Any
    );

=head2 coerce => [ FromType => sub {...}, FromOther => sub { ... } ]

To define different coercions from different type constraints, you may use
an arrayref.

    has num => (
        is      => 'ro',
        isa     => 'Num',
        coerce  => [
            Undef  => sub { -1 },
            Any    => sub { no warnings; length("$_") },
        ],
    );

MooseX::Types type constraints may be used, but beware using the fat comma.

=for Pod::Coverage init_meta

=cut
