package Moonpig::Role::Consumer::ByUsage;
# ABSTRACT: a consumer that charges when told to

use Carp qw(confess croak);
use List::Util qw(sum);
use Moonpig;
use Moonpig::Events::Handler::Method;
use Moonpig::Hold;
use Moonpig::Types qw(ChargePath);
use Moonpig::Util qw(class days event);
use Moose::Role;
use MooseX::Types::Moose qw(Num);

use Moonpig::Logger '$Logger';

with(
  'Moonpig::Role::Consumer',
  'Moonpig::Role::HandlesEvents',
  'Moonpig::Role::StubBuild',
);

use Moonpig::Behavior::EventHandlers;
use Moonpig::Types qw(Millicents Time TimeInterval);

use namespace::autoclean;

implicit_event_handlers {
  return {
    heartbeat => { },
  };
};

has cost_per_unit => (
  is => 'ro',
  isa => Millicents,
  required => 1,
);

# create a replacement when the available funds are no longer enough
# to purchase this many of the commodity
# (if omitted, create replacement when estimated running-out time
# is less than old_age)
has low_water_mark => (
  is => 'ro',
  isa => Num,
  predicate => 'has_low_water_mark',
);

# Return hold object on success, false on insuficient funds
#
sub _create_hold_for_amount {
  my ($self, $amount, $subsidiary_hold) = @_;

  confess "Hold amount $amount < 0" if $amount < 0;

  # This should have been caught before, in create_hold_for_units
  confess "insufficient funds to satisfy $amount"
    unless $self->has_bank && $amount <= $self->unapplied_amount;

  my $hold = Moonpig::Hold->new(
    bank => $self->bank,
    consumer => $self,
    allow_deletion => 1,
    amount => $amount,
    $subsidiary_hold ? (subsidiary_hold => $subsidiary_hold) : (),
  );

  return $hold;
}

sub create_hold_for_units {
  my ($self, $units_requested) = @_;
  my $units_to_get = $units_requested;
  my $units_remaining = $self->units_remaining;

  my $subsidiary_hold;
  if ($units_remaining < $units_requested) {

    # Can't satisfy request
    return unless $self->has_replacement;

    $subsidiary_hold =
      $self->replacement->create_hold_for_units(
        $units_requested - $units_remaining
      ) or return;
    $units_to_get = $units_remaining;
  }

  my $hold = $self->_create_hold_for_amount(
    $self->cost_per_unit * $units_requested,
    $subsidiary_hold,
  );

  unless ($hold) {
    $subsidiary_hold->delete_hold() if $subsidiary_hold;
    return;
  }

  {
    my $low_water_mark =
      $self->has_low_water_mark ? $self->low_water_mark : $units_requested;
    if ($self->units_remaining <= $low_water_mark ||
          $self->estimated_lifetime <= $self->old_age) {
      # XXX code duplicated between ByTime and here
      if ($self->has_replacement) {
        $self->replacement->handle_event(
          event('low-funds',
                { remaining_life => $self->estimated_lifetime }
               ));
      } else {
        $self->handle_event(event('consumer-create-replacement',
                                  { timestamp => Moonpig->env->now,
                                    mri => $self->replacement_mri,
                                  }));
      }
    }
  }

  return $hold;
}

sub units_remaining {
  my ($self) = @_;
  int($self->unapplied_amount / $self->cost_per_unit);
}

sub construct_replacement {
  my ($self, $param) = @_;

  my $repl = $self->ledger->add_consumer(
    $self->meta->name,
    {
      charge_path_prefix => $self->charge_path_prefix(),
      cost_per_unit      => $self->cost_per_unit(),
      ledger             => $self->ledger(),
    $self->has_low_water_mark ?
     (low_water_mark     => $self->low_water_mark()) : (),
      old_age            => $self->old_age(),
      replacement_mri    => $self->replacement_mri(),
      service_uri        => $self->service_uri(),
      %$param,
  });
}

sub create_charge_for_hold {
  my ($self, $hold, $description) = @_;

  croak "No hold provided" unless $hold;
  croak "No charge description provided" unless $description;
  $hold->consumer->guid eq $self->guid
    or confess "misdirected hold";
  $self->has_bank
    or confess "charge committed on bankless consumer";

  my $now = Moonpig->env->now;

  $self->ledger->current_journal->charge({
    desc => $description,
    from => $hold->bank,
    to   => $self,
    date => $now,
    amount    => $hold->amount,
    charge_path => [
      @{$self->charge_path_prefix}, split(/-/, $now->ymd),
     ],
  });
  $hold->delete;
}

# Total amount of money consumed by me in the past $max_age seconds
sub recent_usage {
  my ($self, $max_age) = @_;
  my $transfers = Moonpig::Transfer->all_for_consumer($self);
  my $total_usage = sum(
    map $_->amount,
      grep Moonpig->env->now() - $_->date < $max_age,
        @$transfers
  );
  return $total_usage || 0;
}

# based on the last $days days of transfers, how long might we expect
# the current bank to last, in seconds?
# If no estimate is possible, return 365d
sub estimated_lifetime {
  my ($self) = @_;
  my $days = 30;
  my $recent_daily_usage = $self->recent_usage($days * 86_400) / $days;
  return 86_400 * 365 if $recent_daily_usage == 0;
  return 86_400 * $self->unapplied_amount / $recent_daily_usage;
}

1;
