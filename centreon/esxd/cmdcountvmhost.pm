
package centreon::esxd::cmdcountvmhost;

use strict;
use warnings;
use centreon::esxd::common;

sub new {
    my $class = shift;
    my $self  = {};
    $self->{logger} = shift;
    $self->{commandName} = 'countvmhost';
    
    bless $self, $class;
    return $self;
}

sub getCommandName {
    my $self = shift;
    return $self->{commandName};
}

sub checkArgs {
    my ($self, %options) = @_;

    if (defined($options{arguments}->{esx_hostname}) && $options{arguments}->{esx_hostname} eq "") {
        $options{manager}->{output}->output_add(severity => 'UNKNOWN',
                                                short_msg => "Argument error: esx hostname cannot be null");
        return 1;
    }
    if (defined($options{arguments}->{disconnect_status}) && 
        $options{manager}->{output}->is_litteral_status(status => $options{arguments}->{disconnect_status}) == 0) {
        $options{manager}->{output}->output_add(severity => 'UNKNOWN',
                                                short_msg => "Argument error: wrong value for disconnect status '" . $options{arguments}->{disconnect_status} . "'");
        return 1;
    }
    foreach my $label (('warning_on', 'critical_on', 'warning_off', 'critical_off', 'warning_suspended', 'critical_suspended')) {
        if (($options{manager}->{perfdata}->threshold_validate(label => $label, value => $options{arguments}->{$label})) == 0) {
            $options{manager}->{output}->output_add(severity => 'UNKNOWN',
                                                    short_msg => "Argument error: wrong value for $label value '" . $options{arguments}->{$label} . "'.");
            return 1;
        }
    }
    return 0;
}

sub initArgs {
    my ($self, %options) = @_;
    
    foreach (keys %{$options{arguments}}) {
        $self->{$_} = $options{arguments}->{$_};
    }
    $self->{manager} = centreon::esxd::common::init_response();
    $self->{manager}->{output}->{plugin} = $options{arguments}->{identity};
    foreach my $label (('warning_on', 'critical_on', 'warning_off', 'critical_off', 'warning_suspended', 'critical_suspended')) {
        $self->{manager}->{perfdata}->threshold_validate(label => $label, value => $options{arguments}->{$label});
    }
}

sub set_connector {
    my ($self, %options) = @_;
    
    $self->{obj_esxd} = $options{connector};
}

sub run {
    my $self = shift;

    my %filters = ();
    my $multiple = 0;
    if (defined($self->{esx_hostname}) && !defined($self->{filter})) {
        $filters{name} = qr/^\Q$self->{esx_hostname}\E$/;
    } elsif (!defined($self->{esx_hostname})) {
        $filters{name} = qr/.*/;
    } else {
        $filters{name} = qr/$self->{esx_hostname}/;
    }
    my @properties = ('name', 'vm', 'runtime.connectionState');
    my $result = centreon::esxd::common::get_entities_host($self->{obj_esxd}, 'HostSystem', \%filters, \@properties);
    return if (!defined($result));
    
    if (scalar(@$result) > 1) {
        $multiple = 1;
    }
    
    #return if (centreon::esxd::common::host_state($self->{obj_esxd}, $self->{lhost}, 
    #                                              $$result[0]->{'runtime.connectionState'}->val) == 0);

    my @vm_array = ();
    foreach my $entity_view (@$result) {
        if (defined($entity_view->vm)) {
            @vm_array = (@vm_array, @{$entity_view->vm});
        }
    }
    @properties = ('runtime.powerState');
    my $result2 = centreon::esxd::common::get_views($self->{obj_esxd}, \@vm_array, \@properties);
    return if (!defined($result2));

    if ($multiple == 1) {
        $self->{manager}->{output}->output_add(severity => 'OK',
                                               short_msg => sprintf("All ESX Hosts are ok"));
    }

     foreach my $entity_view (@$result) {
        next if (centreon::esxd::common::host_state(connector => $self->{obj_esxd},
                                                    hostname => $entity_view->{name}, 
                                                    state => $entity_view->{'runtime.connectionState'}->val,
                                                    status => $self->{disconnect_status},
                                                    multiple => $multiple) == 0);
        my $extra_label = '';
        $extra_label = '_' . $entity_view->{name} if ($multiple == 1);
        my %vm_states = (poweredon => 0, poweredoff => 0, suspended => 0);
        if (defined($entity_view->vm)) {
            foreach my $vm_host (@{$entity_view->vm}) {
                foreach my $vm (@{$result2}) {
                    if ($vm_host->{value} eq $vm->{mo_ref}->{value}) {
                        my $power_value = lc($vm->{'runtime.powerState'}->val);
                        $vm_states{$power_value}++;
                        last;
                    }
                }
            }
        }
        
        foreach my $labels ((['poweredon', 'warning_on', 'critical_on'], 
                             ['poweredoff', 'warning_off', 'critical_off'], 
                             ['suspended', 'warning_suspended', 'critical_suspended'])) {
            my $exit = $self->{manager}->{perfdata}->threshold_check(value => $vm_states{$labels->[0]}, 
                                                                     threshold => [ { label => $labels->[2], exit_litteral => 'critical' }, 
                                                                                    { label => $labels->[1], exit_litteral => 'warning' } ]);
            $self->{manager}->{output}->output_add(long_msg => sprintf("'%s' %s VM(s) %s", $entity_view->{name},
                                            $vm_states{$labels->[0]},
                                            $labels->[0]));
            if ($multiple == 0 ||
                !$self->{manager}->{output}->is_status(value => $exit, compare => 'ok', litteral => 1)) {
                $self->{manager}->{output}->output_add(severity => $exit,
                                                       short_msg => sprintf("'%s' %s VM(s) %s", $entity_view->{name},
                                            $vm_states{$labels->[0]},
                                            $labels->[0]));
            }
            
            $self->{manager}->{output}->perfdata_add(label => $labels->[0] . $extra_label,
                                                 value => $vm_states{$labels->[0]},
                                                 warning => $self->{manager}->{perfdata}->get_perfdata_for_output(label => $labels->[1]),
                                                 critical => $self->{manager}->{perfdata}->get_perfdata_for_output(label => $labels->[2]),
                                                 min => 0, max => $vm_states{poweredoff} + $vm_states{suspended} + $vm_states{poweredon});
        }
    }
}

1;