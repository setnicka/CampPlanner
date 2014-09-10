package KSP::CampPlanner::View;
# CampPlanner - plan games and activities during KSP camps (view part of the MVC architecture)
# (c) 2013-2014 Jiří Setnička <setnicka@seznam.cz>

use common::sense;
use locale;

use KSP;
use KSP::CGI;
use UCW::CGI;

use KSP::HTML::Helper;
use KSP::HTML::Form;
use Date::Parse;
use Text::Markdown qw(&markdown);
use Text::Wrap;

use Encode;
use POSIX;
use Data::Dumper; # testing

sub new {
	my $class = shift;
	my $main = shift;
	my $self = {
		Main => $main,
		_camp => $main->{_camp},
		_days => $main->{_days},
		_timeslots => $main->{_timeslots},
		_db => $main->{_db},
		_flashMessage => '',
		# Translate and settings for UI
		tr_gametype => { game => 'Hra', lecture => 'Přednáška', other => 'Jiné' },
		tr_orgtype => { garant => 'Garant', assistant => 'Pomocník', primary => 'Na hru', preparation => 'Na přípravu', cleanup => 'Na úklid' },
		tr_slottype => { primary => 'Probíhá', preparation => 'Příprava', cleanup => 'Úklid' },
			tr_slottype_editorder => [ 'preparation', 'primary', 'cleanup' ],
			tr_slottype_displayorder => [ 'primary', 'preparation', 'cleanup' ],
		tr_place => {inside => 'Uvnitř', outside => 'Venku' }
	};
	bless $self, $class;
	return $self;
}

sub flashMessage($$) {
	my ($self, $flashMessage) = @_;
	$self->{_flashMessage} = sprintf '<div class="flashMessage %s">%s</div>', $flashMessage->[0], $flashMessage->[1];
}

sub setDB($) {
	my $self = shift;
	my $db = shift;
	$self->{_db} = $db;
}

########################
# Versions and commits #
########################
sub printCommitHeader() {
	my ($self, @diffs) = @_;

	my @gamelist;
	for my $plan_id (keys %{$self->{_db}->{plans}}) {
		push(@gamelist, [ $plan_id, $self->{_db}->{plans}->{$plan_id}->{name} ]) if $self->{_db}->{plans}->{$plan_id}->{modified};
	}
	@gamelist = sort { $a->[1] cmp $b->[1] } @gamelist;

	print "<div class='detailBox fullwidth'>\n<b>Necommitnuté změny v následujících hrách:</b><br>\n<form method='get' action='?mode=diff'><p><input type='hidden' name='mode' value='diff'>\n" if (@gamelist);
	for my $plan (@gamelist) {
		printf "<input type='checkbox' class='diffcheckbox' name='showdiff' value='%i'%s> %s <a href='?mode=diff&amp;showdiff=%i'>[Zobrazit diff]</a><br>\n",
		$plan->[0], (@diffs && $diffs[0] == $plan->[0] ? 'checked' : ''),
		$plan->[1], $plan->[0];
		shift @diffs if (@diffs && $diffs[0] == $plan->[0]);
	}
	printf "<input type='submit' value='Zobraz diffy'>\n<button onclick='jQuery(\"input.diffcheckbox\").prop(\"checked\",true);'>Zvol vše</button>\n</p></form>\n</div>\n\n" if (@gamelist);
}

sub showDiffs(@) {
	my ($self, @diffs) = @_;

	print "<h1>Změny ve hrách</h1>\n\n";

	$self->printCommitHeader(map $_->[0], @diffs);

	print <<EOF;
<span style='float: right;'>
	<a href='?mode=gamelist'>Seznam her</a>,
	<a href='?mode=timetable'>Celý rozvrh</a>,
</span><div class='cleaner'></div>
EOF

	print "<form method='post'>
<b>Commit message:</b><br>
<textarea name='commit_message' cols='40' rows='5'></textarea><br>
<input type='submit' name='commitsubmit' value='Commitni všechny zobrazené změny'>
</form>";

	foreach (@diffs) {
		printf "<h3>Změny ve hře <a href='?mode=detail&amp;plan_id=%i'>%s</a>:</h3>\n<pre>%s</pre>\n<br>\n",
			$_->[0],
			$self->{_db}->{plans}->{$_->[0]}->{name},
			$self->colorDiff($_->[1]);
	}

	print "<form method='post'>
<b>Commit message:</b><br>
<textarea name='commit_message' cols='40' rows='5'></textarea><br>
<input type='submit' name='commitsubmit' value='Commitni všechny zobrazené změny'>
</form>";
}


#############
# Timetable #
#############
sub printTimetableHeader($$$) {
	my $self = shift;
	my $mode = shift;
	my $id = shift; # identificator of org, or plan_id

	printf "<h1>Rozvrh soustředění%s</h1>\n\n",
		$mode eq 'game' ? " pro hru: $self->{_db}->{plans}->{$id}->{name}" :
		$mode eq 'org' ? " pro orga: $id" :
		$mode eq 'freeorgs' ? " a volní orgové" :
		$mode eq 'singleedit' ? " - editace slotů: $self->{_db}->{plans}->{$id}->{name}" : "";

	$self->printCommitHeader();

	print "<div id='drag' style='position: absolute;'>\n" if $mode eq 'edit';

	printf "%s\n", $self->{_flashMessage} if length $self->{_flashMessage};
	printf "<span style='float: right;'>\n<a href='?mode=gamelist'>Seznam her</a>, "
		.($mode ne 'full' ? "<a href='?mode=timetable'>Rozvrh</a>, " : "")
		.($mode ne 'singleedit' ? "<a href='?mode=edit&amp;new=1'>Nová hra</a>, " : "<a href='?mode=detail&amp;plan_id=$id'>Detail hry</a>, ")
	."<a href='?mode=materials'>Materiál</a>, <a href='?mode=todos'>To-do</a>"
	."</span><div class='cleaner'></div>\n";
}

sub printTimetableFilter($$$) {
	my $self = shift;
	my $mode = shift;
	my $id = shift; # identificator of org, or plan_id

	my @gamelist;
	for my $plan_id (keys %{$self->{_db}->{plans}}) {
		push(@gamelist, [ $plan_id, $self->{_db}->{plans}->{$plan_id}->{name} ]);
	}
	@gamelist = sort { $a->[1] cmp $b->[1] } @gamelist;
	unshift(@gamelist, [ 0, '= Vyberte hru =']); # push as first

	my %orglist;
	for my $key (keys %{$self->{_db}->{orgs}}) {
		my $orgname = $self->{_db}->{orgs}->{$key}->{orgname};
		$orglist{$orgname} = [ $orgname, $orgname ]; # we want only unique items - it will be exactly the values of this hash
	}
	my @orglist = sort { $a->[1] cmp $b->[1] } values %orglist;
	unshift(@orglist, [ 0, '= Vyberte orga =']); #push as first

	my $form = new KSP::HTML::Form;
	print "<table id='legend' class='campPlanner'><tr>
		<th class='mark'>Legenda:
		<td class='mark'>Venkovní hra<div class='event game outside'></div>
		<td class='mark'>Vniřní hra<div class='event game inside'></div>
		<td class='mark'>Ostatní<div class='event lecture'></div>
		<th class='mark'>Pohled:";
		print "<td class='mark'><a href='?mode=timetable#legend'><button>Celý rozvrh</button></a>" unless $mode eq 'full' && $id == 0;
		print "<td class='mark'><a href='?mode=timetable&amp;timetable=edit#legend'><button>Editace</button></a>" unless $mode eq 'edit';
		print "<td class='mark'><a href='?mode=timetable&amp;timetable=freeorgs#legend'><button>Volní orgové</button></a>
		<td class='mark'><form method='get' action='#legend'><div><input type='hidden' name='mode' value='timetable'>";
			print "<input type='hidden' name='timetable' value='edit'>" if $mode eq 'edit';
			$form->newSimpleInput('plan_id', 'select', {
				options => [@gamelist],
				value => $id,
				special => " style='width: 110px;'"
			});
		print "<input type='submit' value='Zobraz pro hru'></div></form>
		<td class='mark'><form method='get' action='#legend'><div><input type='hidden' name='mode' value='timetable'><input type='hidden' name='timetable' value='org'>";
			$form->newSimpleInput('org', 'select', {
				options => [@orglist],
				value => $id,
				special => " style='width: 110px;'"
			});
		print "<input type='submit' value='Zobraz pro orga'></div></form>
	</table>";

	print "</div>\n" if $mode eq 'edit';
}


sub printTimetable($$$$) {
	my ($self, $mode, $data, $id) = @_;
	# $data - value for table cells

	print "<pre>$self->{debug}</pre>" if $self->{debug};

	# Prepare some lists used in whole big timetable
	my $org = {
		garant => {},
		assistant => {},
		preparation => {},
		primary => {},
		cleanup => {}
	};
	for my $key (keys %{$self->{_db}->{orgs}}) {
		my $orgname = $self->{_db}->{orgs}->{$key}->{orgname};
		my $type = $self->{_db}->{orgs}->{$key}->{type};
		my $plan_id = $self->{_db}->{orgs}->{$key}->{plan_id};
		push(@{$org->{$type}->{$plan_id}}, $orgname);
	}
	my %orglist;
	for my $key (keys %{$self->{_db}->{orgs}}) {
		$orglist{$self->{_db}->{orgs}->{$key}->{orgname}} = 1;
	}

	my %instance;

	my $print_event = sub($$) {
		my ($event, $special_class) = @_;
		my $type = $event->{type};
		my $plan = $data->{$event->{slotname}}->{$event->{key}};
		$instance{"plan$plan->{plan_id}_$type"} = 0 unless defined $instance{"plan$plan->{plan_id}_$type"};
		return sprintf "<div id='plan%d_%se%d' class='event %s %s %s drag %s'><a href='?mode=detail&amp;plan_id=%d' title='Orgové: %s'>%s</a>%s<br><span class='garant' title='Garant'>(%s)</span></div>",
			$plan->{plan_id}, $type, $instance{"plan$plan->{plan_id}_$type"}++,
			$type, $plan->{type}, $plan->{place}, $special_class,
			$plan->{plan_id},
			(defined $org->{$type}->{$plan->{plan_id}} ? join(",", sort @{$org->{$type}->{$plan->{plan_id}}}) : "n/a"),
			$plan->{name},
			($type ne 'primary' ? "<br><small>($self->{tr_slottype}->{$type})</small>" : ""),
			(defined $org->{garant}->{$plan->{plan_id}} ? join(",", sort @{$org->{garant}->{$plan->{plan_id}}}) : "n/a");
	};

	my $print_editevent = sub($$$) {
		my ($plan_id, $type, $special_class) = @_;
		my $plan = $self->{_db}->{plans}->{$plan_id};
		$instance{"plan$plan->{plan_id}_$type"} = 0 unless defined $instance{"plan$plan->{plan_id}_$type"};
		return sprintf "<div id='plan%d_%se%d' class='event %s %s %s drag %s'><span>%s%s</span></div>",
			$plan_id, $type, $instance{"plan$plan->{plan_id}_$type"}++,
			$type, $plan->{type}, $plan->{place}, $special_class,
			$plan->{name}, ($type ne "primary" ? "<small>($self->{tr_slottype}->{$type})</small>" : "");
	};

	my $special_class;

	# Display table with cloneable plans
	if ($mode eq 'edit') {

		print "<h2>Editace rozvrhu</h2>\n";

		print "<p>Pokud máte vypnutý javascript či v prohlížeči nefunguje přetahování, použijte <a href='?mode=timetable&amp;timetable=singleedit&amp;plan_id=$id'>původní editaci slotů</a>.</p>" if $id;

		print "<table class='campPlanner'>\n<tr>";
		print "<th class='mark'><td class='mark'><b>Probíhá</b><td class='mark'><b>Příprava</b><td class='mark'><b>Úklid</b>" x 2;
		my $plan_db = $self->{_db}->{plans};
		my $odd = 1;
		for my $plan_id (sort {
			$plan_db->{$a}->{type} cmp $plan_db->{$b}->{type}
			|| $plan_db->{$a}->{place} cmp $plan_db->{$b}->{place}
			|| $plan_db->{$a}->{name} cmp $plan_db->{$b}->{name}
		} keys %{$plan_db}) {
			print "<tr>" if $odd;
			$odd = !$odd;
			$special_class = ($id && $id != $plan_id) ? ' hide' : '';
			printf "<th class='mark'>%s<td class='mark'>%s<td class='mark'>%s<td class='mark'>%s",
				$self->{_db}->{plans}->{$plan_id}->{name},
				$print_editevent->($plan_id, 'primary', 'clone'.$special_class),
				$print_editevent->($plan_id, 'preparation', 'clone'.$special_class),
				$print_editevent->($plan_id, 'cleanup', 'clone'.$special_class);
		}
		print "</table>\n\n";

		print "<form method='post' action='?mode=timetable&amp;timetable=edit' onsubmit='saveTimetableJSON();'>\n";
		print "<p><input id='timetable_content' type='hidden' name='timetable_content'><input type='submit' name='timetableeditsubmit' value='Uložit změny v rozvrhu'>\n";
		print "Přetahujte sloty her do rozvrhu. Pro přemístění slotu ho stačí přetáhnout do jiného políčka, pro odstranění slotu ho přetáhněte na [Koš].</p>\n\n";
	}


	print "<table id='campPlanner' class='campPlanner $mode'>\n";
	print "<thead>\n<tr><th class='trash'>";
	print "<form method='post' action='?mode=timetable&amp;timetable=edit'>\n<input type='submit' name='singleeditsubmit' value='Ulož'>\n" if $mode eq 'singleedit';
	print "[Koš]" if $mode eq 'edit';
	print "<a href='?mode=timetable&amp;timetable=edit'>[Edit]</a>" if $mode ne 'edit';
	print "</th>";
	for my $slot (sort keys %{$self->{_timeslots}}) {
		print "<th class='mark'>$self->{_timeslots}->{$slot}</th>"
	}
	print "</tr>\n</thead>\n\n";

	for my $day (sort keys %{$self->{_days}}) {
		my $day_slots = {};
		my $max_index = 0;
		my $last_slot = '';
		my $last_row = {};

		# A. Compute timetable "pattern"
		for my $slot (sort keys %{$self->{_timeslots}}) {
			$day_slots->{$slot} = {};
			given ($mode) {
				# Full-timetable and org-timetable are the same (but org-timetable contains only subset of games)
				when (['full', 'org', 'edit']) {
					for my $type ( @{$self->{tr_slottype_displayorder}}) {
						next unless defined $data->{"${type}${day}_${slot}"};
						# 1. Set the same row as in the last slot (continuos events)
						for my $key (keys %{$data->{"${type}${day}_${slot}"}}) {
							$day_slots->{$slot}->{$last_row->{"${type}_${key}"}} = {
								type => $type,
								key => $key,
								slotname => "${type}${day}_${last_slot}"
							} if defined $data->{"${type}${day}_${last_slot}"} && defined $data->{"${type}${day}_${last_slot}"}->{$key}
						}
						# 2. fill others events
						for my $key (keys %{$data->{"${type}${day}_${slot}"}}) {
							unless (defined $data->{"${type}${day}_${last_slot}"} && defined $data->{"${type}${day}_${last_slot}"}->{$key}) {
								my $i = 0;
								$i++ while defined $day_slots->{$slot}->{$i};
								$day_slots->{$slot}->{$i} = {
									type => $type,
									key => $key,
									slotname => "${type}${day}_${slot}"
								};
								$last_row->{"${type}_${key}"} = $i;
								$max_index = $i if $i > $max_index;
							}
						}
					}
				}
				when ('freeorgs') {
					$day_slots->{$slot} = [ grep {!defined $data->{"${day}_${slot}"}->{$_}} sort keys %orglist ];
				}
				when ('singleedit') {
					map { $day_slots->{$slot}->{$_} = (defined $data->{$_}->{"${day}_${slot}"}) } @{$self->{tr_slottype_editorder}};
				}
			}
			$last_slot = $slot;
		}

		# B. Output timetable pattern
		printf "<tbody>\n<tr><th%s class='mark'>%s</th>\n", ($max_index > 0 && $mode ne 'edit' ? sprintf " rowspan='%d'", $max_index + 1 : '') , $self->{_days}->{$day};
		given ($mode) {
			when ('edit') {
				for my $slot (sort keys %{$self->{_timeslots}}) {
					print "<td>";
					for my $i (0..$max_index) {
						if (defined $day_slots->{$slot}->{$i}) {
							$special_class = ($id && $id != $day_slots->{$slot}->{$i}->{key}) ? 'hide' : '';
							print $print_editevent->($day_slots->{$slot}->{$i}->{key}, $day_slots->{$slot}->{$i}->{type}, $special_class);
						}
					}
					print "</td>\n";
				}
			}
			when (['full', 'org']) {
				for my $i (0..$max_index) {
					print "<tr>" unless $i == 0;
					my $blank_span = 0;
					my $event_span = 0;
					my $last_slot = '';
					for my $slot (sort keys %{$self->{_timeslots}}) {
						if (defined $day_slots->{$slot}->{$i}) {
							print "<td colspan='$blank_span'></td>\n" if $blank_span;
							$blank_span = 0;
							my $a = $day_slots->{$slot}->{$i};
							my $b = $day_slots->{$last_slot}->{$i};
							if ($event_span && ($a->{key} != $b->{key} || $a->{type} ne $b->{type})) {
								# Different event
								$special_class = ($id && $id != $day_slots->{$last_slot}->{$i}->{key}) ? 'hide' : '';
								printf "<td colspan='%d'>%s</td>\n", $event_span, $print_event->($day_slots->{$last_slot}->{$i}, $special_class);
								$event_span = 0;
							}
							$event_span++;
						} else {
							if ($event_span) {
								# Ending event
								$special_class = ($id && $id != $day_slots->{$last_slot}->{$i}->{key}) ? 'hide' : '';
								printf "<td colspan='%d'>%s</td>\n", $event_span, $print_event->($day_slots->{$last_slot}->{$i}, $special_class);
								$event_span = 0;
							}
							$blank_span++;
						}
						$last_slot = $slot;
					}
					print "<td colspan='$blank_span'></td>\n" if $blank_span;
					if ($event_span) {
						$special_class = ($id && $id != $day_slots->{$last_slot}->{$i}->{key}) ? 'hide' : '';
						printf "<td colspan='%d'>%s</td>\n", $event_span, $print_event->($day_slots->{$last_slot}->{$i}, $special_class);
					}
					print "</tr>\n";
				}
			}
			when ('freeorgs') {
				for my $slot (sort keys %{$self->{_timeslots}}) {
					print "<td class='border'>";
					print join(", ",
						map { sprintf "<a href='?mode=timetable&amp;timetable=org&amp;org=%s'>%s</a>", url_escape($_), $_ }
						@{$day_slots->{$slot}}
					);
					print "</td>\n";
				}
			}
			when ('singleedit') {
				for my $slot (sort keys %{$self->{_timeslots}}) {
					print "<td class='border singleedit'>";
					for my $type ( @{$self->{tr_slottype_editorder}}) {
						printf "<input type='checkbox' name='%s' %s><small>%s</small><br>\n",
							"${day}_${slot}_$type",
							$day_slots->{$slot}->{$type} ? "checked='checked'" : "",
							$self->{tr_slottype}->{$type};
					}
					print "</td>\n";
				}
			}
		}
		print "</tbody>\n\n";
	}
	print "</table>\n\n";

	print "<p><input type='submit' name='singleeditsubmit' value='Ulož'></p></form>\n\n" if $mode eq 'singleedit';
	print "<p><input type='submit' name='timetableeditsubmit' value='Uložit změny v rozvrhu'></p></form>\n\n" if $mode eq 'edit';
}

sub convertSlotname($$) {
	my ($self, $slotname) = @_;

	my @weekdays_names = ('Neděle', 'Pondělí', 'Úterý', 'Středa', 'Čtvrtek', 'Pátek', 'Sobota');
	my ($date, $slot) = ($slotname =~ /^([^_]*)_(.*)$/);
	my $day = $weekdays_names[strftime("%w",localtime(str2time($date)))];
	return "$day($self->{_timeslots}->{$slot})";
}

# Returns string with text represenation of the game (used for diffs)
sub textSummary($$$$$) {
	my ($self, $plan_id, $db_materials, $db_todos, $db_tags) = @_;

	my $db_plan = $self->{_db}->{plans}->{$plan_id};

	my $output = sprintf "Detail hry: $self->{_db}->{plans}->{$plan_id}->{name}\n\n";

	my $org = {
		garant => [],
		assistant => [],
		preparation => [],
		primary => [],
		cleanup => []
	};
	for my $key (keys %{$self->{_db}->{orgs}}) {
		my $orgname = $self->{_db}->{orgs}->{$key}->{orgname};
		my $type = $self->{_db}->{orgs}->{$key}->{type};
		if ($self->{_db}->{orgs}->{$key}->{plan_id} == $plan_id) {
			push (@{$org->{$type}}, sprintf "Org(%s): %s", $type, $orgname )
		}
	}
	my @tags;
	for my $key (keys %{$self->{_db}->{tags}}) {
		my $tag = $self->{_db}->{tags}->{$key}->{tag};
		if ($self->{_db}->{tags}->{$key}->{plan_id} == $plan_id) {
			push (@tags, sprintf "Tag: %s", $tag )
		}
	}

	$output .= sprintf <<EOF,
Typ: %s
Vybraná: %s
Místo: %s
%s%s%s
%s

EOF
	$self->{tr_gametype}->{$db_plan->{type}},
	$db_plan->{chosen} ? "Ano" : "Ne",
	$self->{tr_place}->{$db_plan->{place}},
	join("\n", sort @{$org->{garant}}).(scalar @{$org->{garant}} ? "\n" : ""),
	join("\n", sort @{$org->{assistant}}).(scalar @{$org->{assistant}} ? "\n" : ""),
	join("\n", sort @tags).(scalar @tags ? "\n" : ""),
	wrap('', '', $db_plan->{description});

	for my $type (@{$self->{tr_slottype_displayorder}}) {
		my $slots_display = join("\n",
			map { sprintf "Slot(%s): %s", $type, $self->convertSlotname($self->{_db}->{slots}->{$_}->{timeslot}) }
			grep { $self->{_db}->{slots}->{$_}->{plan_id} == $plan_id && $self->{_db}->{slots}->{$_}->{type} eq $type }
			sort keys %{$self->{_db}->{slots}}
		);
		my $orgs_display = join("\n", sort @{$org->{$type}}); # orgnames already have "Org(type):" prefix
		$slots_display .= "\n" if $slots_display;
		$orgs_display .= "\n" if $orgs_display;

		$output .= sprintf("%s%s", $slots_display, $orgs_display);
	};

	$output .= join ('', map { sprintf "Material(%s): %s%s\n",
			$_->{completed} ? 'completed' : 'active',
			$_->{name},
			length $_->{note} ? " ($_->{note})" : '' }
		sort { $a->{material_id} cmp $b->{material_id} } values %{$db_materials}
	);

	$output .= join ('', map { sprintf "TODO(%s): %s\n",
			$_->{completed} ? 'completed' : 'active',
			$_->{text} }
		sort { $a->{todo_id} cmp $b->{todo_id} } values %{$db_todos}
	);

	# On the end we want only one newline
	$output =~ s/\s+$/\n/;
	return $output;
}

sub colorDiff($) {
	my ($self, $diff) = @_;
	my $colorDiff = '';
	for (split /^/, $diff) {
		$colorDiff .= $_ unless $_ =~ /^[-+]/;
		$colorDiff .= sprintf '<font color="green">%s</font>', $_ if $_ =~ /^\+/;
		$colorDiff .= sprintf '<font color="red">%s</font>', $_ if $_ =~ /^-/;
	}
	return $colorDiff;
}

# Prints content of a HTML page with the game detail
sub printDetail($$$$$) {
	my ($self, $plan_id, $db_materials, $db_todos, $db_tags) = @_;

	my $db_plan = $self->{_db}->{plans}->{$plan_id};

	#printf "<pre>%s</pre>", $self->colorDiff($diff);

	printf "<h1>Detail hry: $self->{_db}->{plans}->{$plan_id}->{name}</h1>\n";

	$self->printCommitHeader();

	printf "%s\n", $self->{_flashMessage} if length $self->{_flashMessage};
	my $chosen = $db_plan->{chosen} ? "<font color='green'>Ano</font>" : "<font color='red'>Ne</font>";
	my $description = $db_plan->{description};
	$description = markdown($description);

	my $org = {
		garant => [],
		assistant => [],
		preparation => [],
		primary => [],
		cleanup => []
	};
	for my $key (keys %{$self->{_db}->{orgs}}) {
		my $orgname = $self->{_db}->{orgs}->{$key}->{orgname};
		my $type = $self->{_db}->{orgs}->{$key}->{type};
		if ($self->{_db}->{orgs}->{$key}->{plan_id} == $plan_id) {
			push (@{$org->{$type}}, sprintf "<a href='?mode=timetable&amp;timetable=org&amp;org=%s' title='Zobrazit rozvrh orga'>%s</a><small>(<a href='?mode=detail&amp;plan_id=%d&amp;remove=org&amp;remove_type=%s&amp;remove_name=%s' title='Odstranit orga'><font color='red'>X</font></a>)</small>",
				url_escape($orgname), $orgname,
				$plan_id, url_escape($type), url_escape($orgname),
			)
		}
	}
	my @tags;
	for my $key (keys %{$self->{_db}->{tags}}) {
		my $tag = $self->{_db}->{tags}->{$key}->{tag};
		if ($self->{_db}->{tags}->{$key}->{plan_id} == $plan_id) {
			push (@tags, sprintf "%s<small>(<a href='?mode=detail&amp;plan_id=%d&amp;remove=tag&amp;remove_name=%s' title='Odstranit tag'><font color='red'>X</font></a>)</small>",
				$tag, $plan_id, url_escape($tag)
			)
		}
	}

	*add_dialog = sub($$) {
		my $add = shift; # tag/org
		my $type = shift;
		return sprintf <<EOF;
<a href="#" onclick="jQuery(this).hide(); jQuery('#${add}${type}_add').show(); return false;"><small>(+přidat)</small></a>
<div class="javascript_hidden" id="${add}${type}_add"><form method="post">
	<input type="hidden" name="add" value="$add">
	<input type="hidden" name="add_type" value="$type">
	<input type="text" name="add_name">
	<input type="submit" value="Přidat">
</form></div>
EOF
	};

	printf <<EOF,
<span style='float: right;'>
	<a href='?mode=gamelist'>Seznam her</a>,
	<a href='?mode=timetable'>Celý rozvrh</a>,
	<a href='?mode=timetable&amp;plan_id=$plan_id'>Rozvrh hry</a>,
	<a href='?mode=edit&amp;plan_id=$plan_id'>[Editovat detaily hry]</a>,
	<a href='?mode=timetable&amp;timetable=edit&amp;plan_id=$plan_id'>[Editovat sloty hry]</a>
</span><div class='cleaner'></div>

<div class="detailBox fullwidth">
<table>
	<tr><th>Typ:</th><td>%s</td></tr>
	<tr><th>Vybraná:</th><td>%s</td></tr>
	<tr><th>Místo:</th><td>%s</td></tr>
	<tr><th rowspan=2>Garant:</th><td>%s</td></tr>
	<tr><td>%s</td></tr>
	<tr><th rowspan=2>Pomocníci:</th><td>%s</td></tr>
	<tr><td>%s</td></tr>
	<tr><th rowspan=2>Tagy:</th><td>%s</td></tr>
	<tr><td>%s</td></tr>
</table>
<br>
<b>Popis:</b><br>
%s

</div>
EOF
	$self->{tr_gametype}->{$db_plan->{type}},
	$chosen,
	$self->{tr_place}->{$db_plan->{place}},
	join(', ', sort @{$org->{garant}}), add_dialog('org', 'garant'),
	join(', ', sort @{$org->{assistant}}), add_dialog('org', 'assistant'),
	join(', ', sort @tags), add_dialog('tag', 'tag'),
	$description;

	my @slots_display;
	for my $type (@{$self->{tr_slottype_editorder}}) {
		push @slots_display, sprintf ( <<EOF,
<h3>%s</h3>
<table>
	<tr><th>Sloty:</th><td>%s</td></tr>
	<tr><th rowspan=2>Orgové:</th><td>%s</td></tr>
	<tr><td>%s</td></tr>
</table>
EOF
			$self->{tr_slottype}->{$type},
			join(', ',
				map { $self->convertSlotname($self->{_db}->{slots}->{$_}->{timeslot}) }
				grep { $self->{_db}->{slots}->{$_}->{plan_id} == $plan_id && $self->{_db}->{slots}->{$_}->{type} eq $type }
				sort keys %{$self->{_db}->{slots}}
			),
			join(', ', sort @{$org->{$type}}),
			add_dialog('org', $type)
		);
	}

	printf <<EOF, join( '<br>', @slots_display);
<h2>Časové sloty a orgové</h2>

<div class="detailBox fullwidth">
%s
</div>
EOF

	my $edit_material = $self->{Main}->{_edit_material};
	my $edit_todo = $self->{Main}->{_edit_todo};

	printf <<EOF,
<div class="detailBox left" id="material">
<h2>Materiál</h2>
<ul>
%s
</ul>
<hr>
<h3>%s materiál</h3>
<form method="post">
	<input type="hidden" name="add" value="material">
	<input type="hidden" name="edit_material" value="%d">
	<table>
	<tr>
		<th>Materiál:</th>
		<td><input type="text" name="add_name" value="%s"></td>
		<td rowspan="2"><input type="submit" value="%s"></td>
	</tr><tr>
		<th>Poznámka:</th>
		<td><textarea name="add_note">%s</textarea></td>
	</tr>
	</table>
</form>
</div>
EOF
	join ("\n",
		map { sprintf "<li style='list-style-type: none;'>%s %s<small>
		(<a href='?mode=detail&amp;plan_id=%d&amp;remove=material&amp;remove_id=%d' title='Odstranit materiál'><font color='red'>Odstranit</font></a>
		<a href='?mode=detail&amp;plan_id=%d&amp;edit_material=%d#material' title='Editovat materiál'>Editovat</a>)
		</small>
		<br><font color='#444444'>%s</font>",
			sprintf ("<a style='text-decoration: none; margin-left: -17px;' href='?mode=detail&amp;plan_id=%d&amp;set_completed=material&amp;set_completed_id=%d&amp;set_completed_value=%d' title='%s'>%s</a>",
				$plan_id, $_->{material_id}, 1 - $_->{completed},
				$_->{completed} ? 'Sehnáno -> změnit stav na Není' : 'Není -> Změnit stav na Sehnáno',
				$_->{completed} ? '<font color="green">☑</font>' : '<font color="red">☐</font>'
			), $_->{name},
			$plan_id, $_->{material_id},
			$plan_id, $_->{material_id},
			$_->{note}
		} sort { $a->{material_id} cmp $b->{material_id} } values %{$db_materials}
	),
	($edit_material != 0 && $db_materials->{$edit_material} ? 'Editovat' : 'Přidat'),
	$edit_material,
	($edit_material != 0 && $db_materials->{$edit_material} ? $db_materials->{$edit_material}->{name} : ''),
	($edit_material != 0 && $db_materials->{$edit_material} ? 'Uložit' : 'Přidat'),
	($edit_material != 0 && $db_materials->{$edit_material} ? $db_materials->{$edit_material}->{note} : '');


	printf <<EOF,
<div class="detailBox right" id="todo">
<h2>To-do</h2>
<ul>
%s
</ul>
<hr>
<h3>%s To-do</h3>
<form method="post">
	<input type="hidden" name="add" value="todo">
	<input type="hidden" name="edit_todo" value="%d">
	<table>
	<tr>
		<th>To-do:</th>
		<td><textarea name="add_note">%s</textarea></td>
		<td><input type="submit" value="%s"></td>
	</tr>
	</table>
</form>
</div>
EOF

	join ("\n",
		map { sprintf "<li style='list-style-type: none;'>%s %s<small>
			(<a href='?mode=detail&amp;plan_id=%d&amp;remove=todo&amp;remove_id=%d' title='Odstranit to-do'><font color='red'>Odstranit</font></a>
			<a href='?mode=detail&amp;plan_id=%d&amp;edit_todo=%d#todo' title='Editovat to-do'>Editovat</a>)
			</small>",
			sprintf ("<a style='text-decoration: none; margin-left: -17px;' href='?mode=detail&amp;plan_id=%d&amp;set_completed=todo&amp;set_completed_id=%d&amp;set_completed_value=%d' title='%s'>%s</a>",
				$plan_id, $_->{todo_id}, 1 - $_->{completed},
				$_->{completed} ? 'Hotovo -> změnit stav na Nutno udělat' : 'Nutno udělat -> Změnit stav na Hotovo',
				$_->{completed} ? '<font color="green">☑</font>' : '<font color="red">☐</font>'
			),
			$_->{text},
			$plan_id, $_->{todo_id},
			$plan_id, $_->{todo_id}
		} sort { $a->{todo_id} cmp $b->{todo_id} } values %{$db_todos}
	),
	($edit_todo != 0 && $db_todos->{$edit_todo} ? 'Editovat' : 'Přidat'),
	$edit_todo,
	($edit_todo != 0 && $db_todos->{$edit_todo} ? $db_todos->{$edit_todo}->{text} : ''),
	($edit_todo != 0 && $db_todos->{$edit_todo} ? 'Uložit' : 'Přidat');


printf <<EOF;
<script type="text/javascript">
jQuery(".javascript_hidden").hide();
</script>
EOF

}

#####################

sub printEdit($$$$) {
	my ( $self, $data, $errors, $plan_id ) = @_;

	printf "<h1>Editace hry: $self->{_db}->{plans}->{$plan_id}->{name}</h1>\n" unless $plan_id == 0;
	printf "<h1>Nová hra</h1>\n" if $plan_id == 0;

	printf "%s\n", $self->{_flashMessage} if length $self->{_flashMessage};
	printf "<span style='float: right;'><a href='?mode=timetable'>Rozvrh</a>"
		.($plan_id!=0?", <a href='?mode=detail&amp;plan_id=$plan_id'>Zpět na detail</a>":"").
	"</span><div class='cleaner'></div>";

	my $form = new KSP::HTML::Form($errors);

	print "<form action='?mode=edit&amp;".($plan_id==0?"new=1":"plan_id=$plan_id")."' method='post'>\n";
	print "<table class='centertable'>\n";

	$form->newInput('Název', 'name', 'text', {value => $data->{name}, special => " size='40'" });
	$form->newInput('Typ', 'type', 'select', {
			options => [ map( [ $_, $self->{tr_gametype}->{$_} ], sort keys %{$self->{tr_gametype}} ) ],
			value => $data->{type}
		});
	$form->newInput('Místo', 'place', 'select', {
			options => [ map( [ $_, $self->{tr_place}->{$_} ], keys %{$self->{tr_place}} ) ],
			value => $data->{place}
		});
	$form->newInput('Vybraná', 'chosen', 'checkbox', {value => 1, checked => $data->{chosen} });
	print "<tr><th colspan='2' style='text-align: center;'>Popis:</th></tr>\n";
	print "</table>\n";
	$form->newSimpleInput('description', 'textarea', {value => $data->{description},
		cols => 70, rows => 30
	});
	print "<div id='epiceditor'></div>\n";

	print "<div class='center'><input type='submit' name='submit' style='margin-top: 1em; padding: .5em' value='Uložit'></div>\n";
	print "</form>\n\n";

	print "<script type='text/javascript'>
	var editor = new EpicEditor({
		container: 'epiceditor',
		textarea: 'description',
		clientSideStorage: false,
		autogrow: true,
		autogrow: {
			minHeight: 300,
			maxHeight: 600
		},
		basePath: '/',
		theme: {
			base: 'css/epiceditor/epiceditor.css',
			editor: 'css/epiceditor/epic-dark.css',
			preview: 'css/ksp.css'
		},
		button: {
			bar: 'show'
		}
	}).load();
	jQuery('#description').hide();\n</script>\n";
}

#####################

sub printGamelist($$$$) {
	my ( $self, $data, $filter ) = @_;
	my @tags_chosen = @{$filter->{tags_chosen}};
	my @tags_rejected = @{$filter->{tags_rejected}};

	printf "<h1>Seznam her</h1>\n";

	$self->printCommitHeader();

	printf "%s\n", $self->{_flashMessage} if length $self->{_flashMessage};
	printf "<span style='float: right;'><a href='?mode=timetable'>Rozvrh</a>, <a href='?mode=edit&amp;new=1'>Nová hra</a>, <a href='?mode=materials'>Materiál</a>, <a href='?mode=todos'>To-do</a></span><div class='cleaner'></div>\n";

	my %taglist;
	for my $key (keys %{$self->{_db}->{tags}}) {
		my $tag = $self->{_db}->{tags}->{$key}->{tag};
		$taglist{$tag} = $tag; # we want only unique items - it will be exactly the values of this hash
	}

	print "<div class='detailBox fullwidth'>\n";
		my $url_link = '';
		map { $url_link .= "&amp;filter_tag1=".url_escape($_) } @tags_chosen;
		map { $url_link .= "&amp;filter_tag0=".url_escape($_) } @tags_rejected;

		printf "<b>Typ:</b> ";
		my %gametype = %{$self->{tr_gametype}};
		$gametype{all} = 'Vše';
		for my $key (sort keys %gametype) {
			printf "<a href='?mode=gamelist%s%s%s'>%s</a>\n",
			join ('', map { sprintf "&amp;filter_%s=%s", $_, $filter->{$_} } qw/place planned/),
			"&amp;filter_type=$key",
			$url_link,
			$filter->{type} eq $key ? "<b>$gametype{$key}</b>" : "<font color='#444444'>$gametype{$key}</font>";
		}
		print "<br>\n";

		printf "<b>Místo:</b> ";
		my %place = %{$self->{tr_place}};
		$place{all} = 'Vše';
		for my $key (sort keys %place) {
			printf "<a href='?mode=gamelist%s%s%s'>%s</a>\n",
			join ('', map { sprintf "&amp;filter_%s=%s", $_, $filter->{$_} } qw/type planned/),
			"&amp;filter_place=$key",
			$url_link,
			$filter->{place} eq $key ? "<b>$place{$key}</b>" : "<font color='#444444'>$place{$key}</font>";
		}
		print "<br>\n";

		printf "<b>Rozvržení:</b> ";
		my %planned = (
			all => 'Vše',
			withslots => 'Rozvržené',
			withoutslots => 'Bez rozvržení'
		);
		for my $key (sort keys %planned) {
			printf "<a href='?mode=gamelist%s%s%s'>%s</a>\n",
			join ('', map { sprintf "&amp;filter_%s=%s", $_, $filter->{$_} } qw/type place/),
			"&amp;filter_planned=$key",
			$url_link,
			$filter->{planned} eq $key ? "<b>$planned{$key}</b>" : "<font color='#444444'>$planned{$key}</font>";
		}
		print "<br>\n";

		print "<b>Tagy:</b><br>\n";
		my @display;
		for my $tag (sort keys %taglist) {
			my $status = (grep { $_ eq $tag } @tags_chosen) ? "chosen" : (grep { $_ eq $tag } @tags_rejected) ? "rejected" : "no";
			$url_link = '';
			map { $url_link .= sprintf "&amp;filter_%s=%s", $_, $filter->{$_} } qw/type place planned/;
			map { $url_link .= "&amp;filter_tag1=".url_escape($_) } grep { $_ ne $tag } @tags_chosen;
			map { $url_link .= "&amp;filter_tag0=".url_escape($_) } grep { $_ ne $tag } @tags_rejected;
			push @display, sprintf "%s
(<a href='?mode=gamelist%s' title='Filtruj hry jen s tagem %s'><font color='green'><b>+</b></font></a>%s
<a href='?mode=gamelist%s' title='Filtruj hry jen bez tagu %s'><font color='red'><b>-</b></font></a>)\n",
				( $status eq "chosen" ? "<font color='green'>$tag</font>" : $status eq "rejected" ? "<font color='red'>$tag</font>" : $tag ),
				"$url_link&amp;filter_tag1=".url_escape($tag), $tag,
				( $status ne "no" ? sprintf "\n<a href='?mode=gamelist%s' title='Zruš filtr pro tag %s'><b>o</b></a>",
					$url_link, $tag : ""
				),
				"$url_link&amp;filter_tag0=".url_escape($tag), $tag;
		}
		print join(', ', @display);
	print "</div>\n\n";

	my (@chosen, @other);

	my $garants = {};
	for my $key (keys %{$self->{_db}->{orgs}}) {
		my $orgname = $self->{_db}->{orgs}->{$key}->{orgname};
		my $type = $self->{_db}->{orgs}->{$key}->{type};
		my $plan_id = $self->{_db}->{orgs}->{$key}->{plan_id};
		push(@{$garants->{$plan_id}}, $orgname) if $type eq 'garant';
	}

	Game:
	for my $plan_id (sort { $data->{$a}->{name} cmp $data->{$b}->{name} } keys %{$data}) {
		my $a = sprintf "<li><a href='?mode=detail&amp;plan_id=%d'>%s</a> <font color='#444444'>(%s, %s)</font> Tagy: %s <font size='1' color='#444444'>(Garant: %s)</font></li>\n",
			$plan_id, $data->{$plan_id}->{name},
			$self->{tr_gametype}->{$data->{$plan_id}->{type}}, $self->{tr_place}->{$data->{$plan_id}->{place}},
			join(', ', map { $self->{_db}->{tags}->{$_}->{tag} } grep { $self->{_db}->{tags}->{$_}->{plan_id} == $plan_id } sort keys %{$self->{_db}->{tags}} ),
			(defined $garants->{$plan_id} ? join(",", sort @{$garants->{$plan_id}}) : "n/a");

		# Filter check -- it is better to do this way than doing multiple SQL JOIN
		next Game if $filter->{type} ne 'all' && $filter->{type} ne $data->{$plan_id}->{type};
		next Game if $filter->{place} ne 'all' && $filter->{place} ne $data->{$plan_id}->{place};
		next Game if ($filter->{planned} eq 'withslots' && $data->{$plan_id}->{number_of_timeslots} == 0) || ($filter->{planned} eq 'withoutslots' && $data->{$plan_id}->{number_of_timeslots} != 0);
		for my $tag (@tags_chosen) {
			next Game unless defined $self->{_db}->{tags}->{encode('utf8',$plan_id.$tag)};
			# encode to utf8 because of indexing hash by raw DB data
		}
		for my $tag (@tags_rejected) {
			next Game if defined $self->{_db}->{tags}->{encode('utf8',$plan_id.$tag)};
			# encode to utf8 because of indexing hash by raw DB data
		}

		if ($data->{$plan_id}->{chosen}) { push @chosen, $a; }
		else { push @other, $a; }
	}

	print "<h4>Vybrané:</h4>\n<ul>\n";
		map print, @chosen;
	print "</ul>\n";

	print "<h4>Ostatní:</h4>\n<ul>\n";
		map print, @other;
	print "</ul>\n"
}

sub printMaterials($$$$) {
	my ($self, $data, $filter) = @_;

	printf "<h1>Seznam materiálu</h1>\n";
	$self->printCommitHeader();
	printf "%s\n", $self->{_flashMessage} if length $self->{_flashMessage};
	printf "<span style='float: right;'><a href='?mode=timetable'>Rozvrh</a>, <a href='?mode=gamelist'>Seznam her</a>, <a href='?mode=todos'>To-do</a></span><div class='cleaner'></div>\n";

	print "<div class='detailBox fullwidth'>\n";
		printf "<b>Stav:</b> ";
		my %completed;
		$completed{all} = 'Vše';
		$completed{1} = 'Sehnané';
		$completed{0} = 'Není';
		for my $key (sort keys %completed) {
			printf "<a href='?mode=materials%s'>%s</a>\n",
			"&amp;filter_completed=$key",
			$filter->{completed} eq $key ? "<b>$completed{$key}</b>" : "<font color='#444444'>$completed{$key}</font>";
		}
	print "</div>\n\n";

	print "<ul>\n";
	Item:
	for my $material_id (sort { $data->{$a}->{name} cmp $data->{$b}->{name} } keys %{$data}) {
		$a = $data->{$material_id};
		# Filter check -- it is better to do this way than doing multiple SQL JOIN
		next Item if $filter->{completed} ne 'all' && $filter->{completed} ne $a->{completed};

		printf "<li style='list-style-type: none;'><span style='margin-left: -15px; margin-right: 5px;'>%s</span>%s (<a href='?mode=detail&amp;plan_id=%d#material'>%s</a>)<br>\n
		<font color='#444444'>%s</font></li>\n",
			$a->{completed} ? '<font color="green" title="Sehnané">☑</font>' : '<font color="red" title="Není">☐</font>',
			$a->{name},
			$a->{plan_id}, $self->{_db}->{plans}->{$a->{plan_id}}->{name},
			$a->{note};
	}
	print "</ul>\n";
}

sub printTodos($$$$) {
	my ($self, $data, $filter) = @_;

	printf "<h1>Seznam To-do</h1>\n";
	$self->printCommitHeader();
	printf "%s\n", $self->{_flashMessage} if length $self->{_flashMessage};
	printf "<span style='float: right;'><a href='?mode=timetable'>Rozvrh</a>, <a href='?mode=gamelist'>Seznam her</a>, <a href='?mode=materials'>Materiál</a></span><div class='cleaner'></div>\n";

	print "<div class='detailBox fullwidth'>\n";
		printf "<b>Stav:</b> ";
		my %completed;
		$completed{all} = 'Vše';
		$completed{1} = 'Hotovo';
		$completed{0} = 'Potřeba udělat';
		for my $key (sort keys %completed) {
			printf "<a href='?mode=todos%s'>%s</a>\n",
			"&amp;filter_completed=$key",
			$filter->{completed} eq $key ? "<b>$completed{$key}</b>" : "<font color='#444444'>$completed{$key}</font>";
		}
	print "</div>\n\n";

	print "<ul>\n";
	Item:
	for my $todo_id (sort { $data->{$a}->{todo_id} cmp $data->{$b}->{todo_id} } keys %{$data}) {
		$a = $data->{$todo_id};
		# Filter check -- it is better to do this way than doing multiple SQL JOIN
		next Item if $filter->{completed} ne 'all' && $filter->{completed} ne $a->{completed};

		printf "<li style='list-style-type: none;'><span style='margin-left: -15px; margin-right: 5px;'>%s</span>%s (<a href='?mode=detail&amp;plan_id=%d#todo'>%s</a>)</li>\n",
			$a->{completed} ? '<font color="green" title="Hotovo">☑</font>' : '<font color="red" title="Je potřeba udělat">☐</font>',
			$a->{text},
			$a->{plan_id}, $self->{_db}->{plans}->{$a->{plan_id}}->{name};
	}
	print "</ul>\n";
}

1;
