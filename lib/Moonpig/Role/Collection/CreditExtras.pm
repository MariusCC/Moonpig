package Moonpig::Role::Collection::CreditExtras;
use Moose::Role;
# ABSTRACT: extra behavior for a ledger's Credit collection

use Moonpig::Util qw(class event);
use Stick::Publisher 0.20110324;
use Stick::Publisher::Publish 0.20110504;

my %OK_ADD_ARG = map {; $_ => 1 } qw(
  type
  attributes
  quote_guid
  send_receipt
);

sub add {
  my ($self, $arg) = @_;
  my $type = $arg->{type};

  my @unknown = grep { ! $OK_ADD_ARG{ $_ } } keys %$arg;
  Moonpig::X->throw("unknown arguments: @unknown") if @unknown;

  return Moonpig->env->storage->do_rw(sub {
    if ($arg->{quote_guid}) {
      my $quote = $self->owner->invoice_collection->find_by_guid({
        guid => $arg->{quote_guid},
      });
      $quote->execute;
    }

    my $credit = $self->owner->add_credit(
      class("Credit::$type"),
      $arg->{attributes},
    );

    if ($arg->{send_receipt}) {
      $self->owner->handle_event(event('send-mkit', {
        kit => 'receipt',
        arg => {
          subject => "Payment received",

          to_addresses => [ $self->owner->contact->email_addresses ],
          credit       => $credit,
          ledger       => $self->owner,
        },
      }));
    }

    # XXX: I have a hard time believing these saves are really useful.
    # -- rjbs, 2012-09-13
    $self->owner->save;
    $self->owner->process_credits;
    $self->owner->save;
    return $credit;
  });
};

1;

