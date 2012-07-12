package Moonpig::Role::LineItem;
# ABSTRACT: a non-charge line item on an invoice
use Moose::Role;
with ('Moonpig::Role::ChargeLike',
      'Moonpig::Role::ConsumerComponent',
      'Moonpig::Role::HandlesEvents',
     );

sub check_amount { 1 }
sub counts_toward_total { 0 }
sub is_charge { 0 }

1;
