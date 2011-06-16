package Moonpig::Role::HasCharges;
# ABSTRACT: something that has a set of charges associated with it
use MooseX::Role::Parameterized;

use namespace::autoclean;

use Moonpig;

use List::Util qw(reduce);
use Moonpig::Types qw(Charge);
use Moonpig::Util qw(class);
use MooseX::Types::Moose qw(ArrayRef);
use Stick::Types qw(StickBool);
use Stick::Util qw(true false);

parameter charges_handle_events => (
  isa      => 'Bool',
  required => 1,
);

role {
  my $p = shift;

  has charges => (
    is  => 'ro',
    isa => ArrayRef[ Charge ],
    init_arg => undef,
    default  => sub {  []  },
    traits   => [ 'Array' ],
    handles  => {
      all_charges => 'elements',
      _add_charge => 'push',
    },
  );

  method total_amount => sub {
    reduce { $a + $b } 0, map { $_->amount } $_[0]->all_charges
  };

  method _objectify_charge => sub {
    my ($self, $input) = @_;
    return $input if blessed $input;

    my $class = $p->charges_handle_events
              ? class('Charge::HandlesEvents')
              : class('Charge');

    $class->new($input);
  };

  method add_charge => sub {
    my ($self, $charge_input) = @_;

    my $charge = $self->_objectify_charge( $charge_input );

    my $handles = $charge->does('Moonpig::Role::HandlesEvents');

    Moonpig::X->throw("bad charge type")
      if $handles xor $p->charges_handle_events;

    $self->_add_charge($charge);

    return $charge;
  };

  has closed => (
    isa     => StickBool,
    coerce  => 1,
    default => 0,
    reader  => 'is_closed',
    writer  => '__set_closed',
  );

  method close   => sub { $_[0]->__set_closed( true ) };
  method is_open => sub { ! $_[0]->is_closed };

  # TODO: make sure that charges added to this container have dates that
  # precede this date. 2010-10-17 mjd@icgroup.com
  has date => (
    is  => 'ro',
    required => 1,
    default => sub { Moonpig->env->now() },
    isa => 'DateTime',
  );
};

1;
