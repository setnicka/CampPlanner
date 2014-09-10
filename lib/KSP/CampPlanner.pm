package KSP::CampPlanner;
# CampPlanner - plan games and activities during KSP camps
# (c) 2013-2014 Jiří Setnička <setnicka@seznam.cz>

use common::sense;
use locale;

use base 'Exporter';

use KSP;
KSP::ensureSSL();
use KSP::CGI;
use UCW::CGI;

use KSP qw(&redirect &current_cgi);
use KSP::DB;
use DateTime qw(&now);
use Date::Parse;
use Text::Diff;
use JSON;

use Encode;
use POSIX;
use Data::Dumper; # testing

# View (MVC architecture)
use KSP::CampPlanner::View;
# Internal version control system
use KSP::CampPlanner::Versions;

our @EXPORT_OK = qw(&new);

sub new {
	my $class = shift;
	my $self = {
		_camp => shift,
		_timeslots => { # Timeslots must have numbers, because of sorting when displaying them
			'1rano' => 'Ráno',
			'2dopoledne' => 'Dopoledne',
			'3poledni_klid' => 'Polední klid',
			'4odpoledne1' => 'Odpoledne (1. část)',
			'5odpoledne2' => 'Odpoledne (2. část)',
			'6po_veceri' => 'Po večeři',
			'7vecer' => 'Večer',
			'8noc' => 'Noc'
		},
		_flashMessages => {
			'timetableSaved' => ['success', 'Rozvrh her uložen'],
			'commitSaved' => ['success', 'Commit uložen'],
			'planSaved' => ['success', 'Údaje úspěšně uloženy']
		},
		_data => {},
		_errors => {}
	};

	bless $self, $class;
	return $self;
}

##########################################
# Configuration and checking subroutines #
##########################################
sub setDays($$) {
	my ( $self, $start_date, $camp_length ) = @_;
	if (str2time($start_date) && $camp_length =~ /\d+/ ) {
		$self->{_start_date} = str2time($start_date);
		$self->{_camp_length} = $camp_length; # in days
	} else { die "Invalid date format for KSP::CampPlanner::setDays()"; }
}

sub setTimeslots($) {
	my ( $self, $timeslots ) = @_;
	$self->{_timeslots} = $timeslots;
}

###########################
# Primary logic functions #
###########################
sub prepare($) {
	my $self = shift;
	$self->{_user} = shift;
	die "No user for CampPlanner::prepare()!" unless defined $self->{_user} && defined $self->{_user}->{id};
	die "Days must be set first (CampPlanner->setDays())!" unless defined $self->{_start_date};

	ensureDB(utf8 => 1);

	$self->loadDatabase(); # Load data from DB and construct some data models

	$self->{View} = new KSP::CampPlanner::View($self);
	$self->{Versions} = new KSP::CampPlanner::Versions($self, $self->{View});

	my @filter_tags_chosen;
	my @filter_tags_rejected;
	my @showdiffs;
	my $data = {};
	my $filter = {};
	# Parse arguments from submitted form (if there are some)
	my $param_table = {
		mode		=> { var => \$self->{_mode}, check => 'timetable|detail|edit|summary|gamelist|diff|checkdiff|materials|todos', default => 'timetable' },
		timetable	=> { var => \$self->{_timetable_mode}, check => 'full|org|freeorgs|singleedit|edit', default => 'full'},
		summary		=> { var => \$self->{_summary_mode}, check => 'todos|materials', default => 'todos'},
		plan_id		=> { var => \$self->{_plan_id}, check => '\d+', default => 0},
		org		=> { var => \$self->{_org} },
		new		=> { var => \$self->{_newgame} },
		message		=> { var => \$self->{flashMessage}, default => ''},
		# Gamelist, materials and todos filter
		filter_tag1	=> { var => \@filter_tags_chosen },
		filter_tag0	=> { var => \@filter_tags_rejected },
		filter_type	=> { var => \$filter->{type}, check => 'game|lecture|other|all', default => 'all' },
		filter_place	=> {var => \$filter->{place}, check => 'inside|outside|all', default => 'all' },
		filter_planned	=> {var => \$filter->{planned}, check => 'withoutslots|withslots|all', default => 'all' },
		filter_completed	=> {var => \$filter->{completed}, check => '1|0|all', default => 'all'},
		# Plan edit
		name		=> { var => \$data->{name} },
		type		=> { var => \$data->{type}, check => 'game|lecture|other' },
		description	=> { var => \$data->{description}, multiline => 1 },
		place		=> { var => \$data->{place}, check => 'inside|outside' },
		chosen		=> { var => \$data->{chosen}, check => '0|1', default => 0 },
		add_tags	=> { var => \$data->{add_tags}, multiline => 1 },
		add_orgs	=> { var => \$data->{add_orgs}, multiline => 1 },
		add_todos	=> { var => \$data->{add_todos}, multiline => 1 },
		add_materials	=> { var => \$data->{add_materials}, multiline => 1 },
		submit		=> { var => \$data->{submit} },
		singleeditsubmit	=> { var => \$data->{singleeditsubmit} },
		timetableeditsubmit	=> { var => \$data->{timetableeditsubmit} },
		timetable_content	=> { var => \$data->{timetable_content}, default => '' },
		# Plan detail (adding/removing tags, orgs, materials and todos)
		add		=> { var => \$self->{_add}, check => 'org|tag|material|todo' },
		add_type	=> { var => \$self->{_add_type}, check => 'garant|assistant|preparation|primary|cleanup' },
		add_name	=> { var => \$self->{_add_name}, default => '' },
		add_note	=> { var => \$self->{_add_note}, multiline => 1, default => '' },
		remove		=> { var => \$self->{_remove} },
		remove_type	=> { var => \$self->{_remove_type} },
		remove_name	=> { var => \$self->{_remove_name} },
		remove_id	=> { var => \$self->{_remove_id} },
		edit_material	=> { var => \$self->{_edit_material}, check => '\d+', default => 0 },
		edit_todo	=> { var => \$self->{_edit_todo}, check => '\d+', default => 0 },
		set_completed	=> { var => \$self->{_set_completed}, check => 'material|todo' },
		set_completed_value	=> { var => \$self->{_set_completed_value}, check => '1|0', default => 1 },
		set_completed_id	=> { var => \$self->{_set_completed_id}, check => '\d+', default => 0 },
		# Internal version control system
		showdiff	=> { var => \@showdiffs },
		commitsubmit	=> { var => \$data->{commitsubmit} },
		commit_message	=> { var => \$data->{commit_message},  multiline => 1 },
	};
	UCW::CGI::parse_args($param_table);
	$filter->{tags_chosen} = \@filter_tags_chosen;
	$filter->{tags_rejected} = \@filter_tags_rejected;
	$self->{_filter} = $filter;
	$self->{_showdiffs} = \@showdiffs;
	$self->{_modified} = 0;

	# If in edit mode and not submitted, then load default values
	if ($self->{_mode} eq 'edit' && !$self->{_newgame} && !$data->{submit} && defined $self->{_db}->{plans}->{$self->{_plan_id}}) {
		my $a = $self->{_db}->{plans}->{$self->{_plan_id}};
		$data->{name} = $a->{name};
		$data->{type} = $a->{type};
		$data->{description} = $a->{description};
		$data->{place} = $a->{place};
		$data->{chosen} = $a->{chosen};
	}
	$self->{_data} = $data;

	# Check all diffs
	# (Time-consuming operation, run only manually)
	if ($self->{_mode} eq 'checkdiff') {
		$self->checkModifiedPlans(keys %{$self->{_db}->{plans}});
		redirect(current_cgi()."?mode=timetable");
	}

	# Edit timetable and redirect
	if ($data->{timetableeditsubmit} && length $data->{timetable_content}) {
		my $timetable_content = from_json($data->{timetable_content}) or die "Could not parse timetable content JSON";

		# 1. Parse into DB slots keys format: CONCAT(plan_id,type,timeslot)
		my $new_slots = {};
		for my $item (@{$timetable_content}) {
			# item name example: plan42_cleanupc0 (where "c0" is "clone tag" at the end, or "e0" is "exists tag")
			$item->[0] =~ m/^plan([0-9]+)_(primary|preparation|cleanup).*/;
			my ($item_id, $item_type) = ($1, $2);
			$item_type =~ s//$1/;
			my $item_day = (sort keys $self->{_days})[$item->[1] - 1];
			my $item_slot = (sort keys $self->{_timeslots})[$item->[2] - 1];
			$new_slots->{"${item_id}${item_type}${item_day}_${item_slot}"} = {
				plan_id => $item_id,
				type => $item_type,
				timeslot => "${item_day}_${item_slot}"
			};
		}

		# 2. tests DB slots to delete
		my %modified = ();
		my @delete;
		for my $key (keys %{$self->{_db}->{slots}}) {
			my $a = $self->{_db}->{slots}->{$key};
			unless (defined $new_slots->{$key}) {
				push(@delete, sprintf "(plan_id='%d' AND type='%s' AND timeslot='%s')", $a->{plan_id}, $a->{type}, $a->{timeslot});
				$modified{$a->{plan_id}} = 1;
			}
		}
		$dbh->do( sprintf '
			DELETE FROM camp_planner_timeslots
			WHERE %s',
			join('OR', @delete)
		) if @delete;

		# 3. tests DB slots to add

		my @add;
		for my $key (keys %{$new_slots}) {
			unless (defined $self->{_db}->{slots}->{$key}) {
				push(@add, sprintf "('%s', '%s', '%s')", $new_slots->{$key}->{plan_id}, $new_slots->{$key}->{type}, $new_slots->{$key}->{timeslot});
				$modified{$new_slots->{$key}->{plan_id}} = 1;
			}
		}
		$dbh->do( sprintf '
			INSERT INTO camp_planner_timeslots(plan_id, type, timeslot)
			VALUES %s',
			join(',', @add)
		) if @add;

		commit();
		$self->checkModifiedPlans(keys %modified);

		redirect(current_cgi()."?mode=timetable&message=timetableSaved");
	}

	# Edit timetable and redirect (old single edit mode)
	if ($self->{_data}->{singleeditsubmit}) {
		my $timeslots = {};
		my $timeslots_param_table = {};
		for my $day (sort keys %{$self->{_days}}) {
			for my $slot (sort keys %{$self->{_timeslots}}) {
				for my $type ('preparation', 'primary', 'cleanup') {
					$timeslots_param_table->{"${day}_${slot}_$type"} = { var => \$timeslots->{"${day}_${slot}_$type"} };
				}
			}
		}
		UCW::CGI::parse_args($timeslots_param_table);

		# Sava data into DB
		my @delete;
		for my $key (keys %{$self->{_db}->{slots}}) {
			my $a = $self->{_db}->{slots}->{$key};
			push(@delete, sprintf "(plan_id='%s' AND type='%s' AND timeslot='%s')",
				$self->{_plan_id}, $a->{type}, $a->{timeslot})
				unless $a->{plan_id} != $self->{_plan_id} || length $timeslots->{"$a->{timeslot}_$a->{type}"};
		}
		my @add;
		for my $key (keys %{$timeslots}) {
			my ($add_slot, $add_type) = ( $key =~ /^(.*)_([^_]*)$/ );
			push(@add, sprintf "('%s', '%s', '%s')",
				$self->{_plan_id}, $add_type, $add_slot)
				unless defined $self->{_db}->{slots}->{"$self->{_plan_id}${add_type}${add_slot}"} || !length $timeslots->{$key};
		}

		if (@delete) {
			$dbh->do( sprintf '
				DELETE FROM camp_planner_timeslots
				WHERE %s',
				join('OR', @delete)
			);
		}

		if (@add) {
			$dbh->do( sprintf '
				INSERT INTO camp_planner_timeslots(plan_id, type, timeslot)
				VALUES %s',
				join(',', @add)
			);
		}
		commit();
		$self->checkModified();

		# Redirect
		redirect(current_cgi()."?mode=timetable&timetable=singleedit&plan_id=$self->{_plan_id}&message=timetableSaved");
	}

	if ($self->{_data}->{commitsubmit}) {
		$self->{Versions}->commitChanges($self->{_showdiffs}, $self->{_data}->{commit_message});
		# Redirect
		redirect(current_cgi()."?mode=timetable&message=commitSaved");
	}

	# Edit plan and redirect
	if ($self->{_data}->{submit} && $self->checkSubmit()) {
		$self->processSubmit();
		redirect(current_cgi()."?mode=detail&plan_id=$self->{_plan_id}&message=planSaved");
	}

	# Check and redirect
	redirect(current_cgi().'?mode=timetable') if
		($self->{_timetable_mode} eq 'org' && $self->{_org} eq 0) || # Unknown org for timetable view -> full timetable
		($self->{_mode} eq 'diff' && !@{$self->{_showdiffs}} ); # No diffs selected
	redirect(current_cgi().'?mode=gamelist') if
		($self->{_mode} eq 'detail' && !defined $self->{_db}->{plans}->{$self->{_plan_id}}); # Unknown game -> gamelist

	# Adding and removing orgs, tags, ... (may redirect to another page)
	$self->detailOperations();

	$self->{_prepared} = 1;
}

# Checks if there are some changed to commit
sub checkModified() {
	my $self = shift;
	my $plan_id = shift;
	$plan_id = $self->{_plan_id} unless $plan_id;
	die "Unknown plan_id!\n" unless $plan_id;

	$self->loadDatabase();
	$self->{View}->setDB($self->{_db});

	my $actual = $self->{Versions}->getActual($plan_id);
	my $last = $self->{Versions}->getLast($plan_id);

	my $diff = diff \$last, \$actual;

	$self->setModified($plan_id, $diff =~ /^\s*$/ ? 0 : 1);
}

sub checkModifiedPlans(@) {
	my $self = shift;
	$self->checkModified($_) for (@_);
}

# Set modified flag used by commit machinery
sub setModified() {
	my $self = shift;
	my $plan_id = shift;
	my $modified = shift;
	$plan_id = $self->{Main}->{_plan_id} unless $plan_id;
	die "Unknown plan_id!\n" unless $plan_id != 0;

	$dbh->do(
		'UPDATE camp_planner
		SET modified=?
		WHERE plan_id=?',
		undef,
		defined $modified ? $modified : 1,
		$plan_id
	);
	commit();
}

sub checkSubmit() {
	my $self = shift;
	my $data = $self->{_data};

	my $errors = {};

	$errors->{name}		= 'Musíš vyplnit název!' unless length $data->{name};
	$errors->{type}		= 'Neznámý typ plánu!' unless $data->{type} =~ /^(game|lecture|other)$/;
	$errors->{place}	= 'Neznámé místo!' unless $data->{place} =~ /^(inside|outside)$/;

	$self->{_errors} = $errors;
	if (keys %$errors) { return 0; }
	else { return 1; }
}

sub processSubmit() {
	my $self = shift;
	my $data = $self->{_data};

	# Write all into DB and we are (almost) finished
	if ($self->{_newgame}) {
		$dbh->do(
			'INSERT INTO camp_planner(
				camp,
				name, type, description, place, chosen)
			VALUES (
				?,
				?, ?, ?, ?, ?)',
			undef,
			$self->{_camp},
			$data->{name}, $data->{type}, $data->{description}, $data->{place}, $data->{chosen}
		);
		$self->{_plan_id} = $dbh->last_insert_id(undef, undef, 'logins', 'uid');
	} else {
		$dbh->do(
			'UPDATE camp_planner
			SET name=?, type=?, description=?, place=?, chosen=?
			WHERE plan_id=?',
			undef,
			$data->{name}, $data->{type}, $data->{description}, $data->{place}, $data->{chosen},
			$self->{_plan_id}
		);
	}
	$self->checkModified();

	# And parse multi-inputs for tags, materials, TODOs and orgs
	# TODO

	commit();
}

#######################

sub show() {
	my $self = shift;
	die "CampPlanner->prepare() must be run first!" unless defined $self->{_prepared};

	# Flash messages

	$self->{View}->flashMessage($self->{_flashMessages}->{$self->{flashMessage}}) if defined $self->{_flashMessages}->{$self->{flashMessage}};

	# Choose action
	given ($self->{_mode}) {
		when ('timetable') {
			$self->{View}->printTimetableHeader($self->{_timetable_mode}, $self->{_timetable_mode} eq 'org' ? $self->{_org} : $self->{_plan_id} );
			my $data = {};
			given ($self->{_timetable_mode}) {
				when (['full', 'edit']) {
					for my $key (keys %{$self->{_db}->{slots}}) {
						my $a = $self->{_db}->{slots}->{$key};
						$data->{"$a->{type}$a->{timeslot}"}->{$a->{plan_id}} = $self->{_db}->{plans}->{$a->{plan_id}};
					}
				}
				when ('freeorgs') {
					my $working_orgs = {};
					my %orglist;
					for my $key (keys %{$self->{_db}->{orgs}}) {
						$orglist{$self->{_db}->{orgs}->{$key}->{orgname}} = 1;
					}
					for my $key (keys %{$self->{_db}->{slots}}) {
						my $a = $self->{_db}->{slots}->{$key};
						for my $org (keys %orglist) {
							$working_orgs->{$a->{timeslot}}->{$org} = 1 if defined $self->{_db}->{orgs}->{encode('utf8',$a->{plan_id}.$a->{type}.$org)};
						}
					}
					# Send working orgs to view instead of filtering free orgs there
					$data = $working_orgs;
				}
				when ('singleedit') {
					$data = {
						preparation => {},
						primary => {},
						cleanup => {}
					};
					for my $key (keys %{$self->{_db}->{slots}}) {
						my $a = $self->{_db}->{slots}->{$key};
						$data->{$a->{type}}->{$a->{timeslot}} = 1 if $a->{plan_id} == $self->{_plan_id};
					}
				}
				when ('org') {
					for my $key (keys %{$self->{_db}->{slots}}) {
						my $a = $self->{_db}->{slots}->{$key};
						if (defined $self->{_db}->{orgs}->{encode('utf8',$a->{plan_id}.$a->{type}.$self->{_org})}) {
							$data->{"$a->{type}$a->{timeslot}"}->{$a->{plan_id}} = $self->{_db}->{plans}->{$a->{plan_id}}
						}
						# encode to utf8 because of indexing hash by raw DB data
					}
				}
			}
			$self->{View}->printTimetable($self->{_timetable_mode}, $data, $self->{_plan_id});
			$self->{View}->printTimetableFilter($self->{_timetable_mode}, $self->{_timetable_mode} eq 'org' ? $self->{_org} : $self->{_plan_id} ) if $self->{_timetable_mode} ne 'singleedit';
		}
		when ('detail') {
			my $db_materials = $dbh->selectall_hashref("
				SELECT *
				FROM camp_planner_materials
				WHERE plan_id=?",
			'material_id', undef, $self->{_plan_id});
			my $db_todos = $dbh->selectall_hashref("
				SELECT *
				FROM camp_planner_todos
				WHERE plan_id=?",
			'todo_id', undef, $self->{_plan_id});
			my $db_tags = $dbh->selectall_hashref("
				SELECT *
				FROM camp_planner_tags
				WHERE plan_id=?",
			'tag', undef, $self->{_plan_id});


			$self->{View}->printDetail( $self->{_plan_id}, $db_materials, $db_todos, $db_tags );
		}
		when ('edit') {
			$self->{View}->printEdit( $self->{_data}, $self->{_errors}, $self->{_newgame}? 0 : $self->{_plan_id} );
		}
		when ('gamelist') {
			my $data = $dbh->selectall_hashref("
				SELECT *, (SELECT COUNT(*) FROM camp_planner_timeslots WHERE plan_id=camp_planner.plan_id) AS number_of_timeslots
				FROM camp_planner
				WHERE camp=?",
			'plan_id', undef, $self->{_camp});

			$self->{View}->printGamelist($data, $self->{_filter});
		}
		when ('materials') {
			my $data = $dbh->selectall_hashref("
				SELECT *
				FROM camp_planner_materials
				WHERE plan_id IN (SELECT plan_id FROM camp_planner WHERE camp=?)",
			'material_id', undef, $self->{_camp});

			$self->{View}->printMaterials($data, $self->{_filter});
		}
		when ('todos') {
			my $data = $dbh->selectall_hashref("
				SELECT *
				FROM camp_planner_todos
				WHERE plan_id IN (SELECT plan_id FROM camp_planner WHERE camp=?)",
			'todo_id', undef, $self->{_camp});

			$self->{View}->printTodos($data, $self->{_filter});
		}
		when ('diff') {
			my @diffs;
			for my $plan_id (@{$self->{_showdiffs}}) {
				my $actual = $self->{Versions}->getActual($plan_id);
				my $last = $self->{Versions}->getLast($plan_id);
				push(@diffs, [$plan_id, diff \$last, \$actual ]);
			}
			$self->{View}->showDiffs(@diffs);
		}
	}
}

sub loadDatabase() {
	my $self = shift;

	my @weekdays_names = ('Ne', 'Po', 'Út', 'St', 'Čt', 'Pá', 'So');
	$self->{_days} = {};
	for (my $i=0; $i<$self->{_camp_length}; $i++) {
		my $time = $self->{_start_date}+$i*86400; # 60*60*24 - 1 day
		$self->{_days}->{strftime("%F",localtime($time))} = sprintf "%s<br><small>%s</small>",
			$weekdays_names[strftime("%w",localtime($time))],
			strftime("%d.%m.",localtime($time));
	}

	my $db = {};
	$db->{plans} = $dbh->selectall_hashref("
		SELECT *
		FROM camp_planner
		WHERE camp=?",
	'plan_id', undef, $self->{_camp});

	$db->{slots} = $dbh->selectall_hashref("
		SELECT CONCAT(plan_id,type,timeslot), plan_id, type, timeslot
		FROM camp_planner_timeslots
		WHERE plan_id IN (SELECT plan_id FROM camp_planner WHERE camp=?)",
	1, undef, $self->{_camp});

	$db->{orgs} = $dbh->selectall_hashref("
		SELECT CONCAT(plan_id,type,orgname), plan_id, type, orgname
		FROM camp_planner_orgs
		WHERE plan_id IN (SELECT plan_id FROM camp_planner WHERE camp=?)",
	1, undef, $self->{_camp});

	$db->{tags} = $dbh->selectall_hashref("
		SELECT CONCAT(plan_id,tag), plan_id, tag
		FROM camp_planner_tags
		WHERE plan_id IN (SELECT plan_id FROM camp_planner WHERE camp=?)",
	1, undef, $self->{_camp});

	$self->{_db} = $db;
}

sub detailOperations($) {
	my $self = shift;

	if ($self->{_mode} eq 'detail' && length $self->{_add_name}
		&& ( ($self->{_add} eq 'org' && $self->{_add_type}) || $self->{_add} eq 'tag' )
	) {
		given ($self->{_add}) {
			when ('org') {
				$dbh->do(
					'INSERT INTO camp_planner_orgs(plan_id, type, orgname)
					VALUES (?, ?, ?)',
					undef,
					$self->{_plan_id}, $self->{_add_type}, $self->{_add_name}
				) unless defined $self->{_db}->{orgs}->{encode('utf8',$self->{_plan_id}.$self->{_add_type}.$self->{_add_name})};
				# encode to utf8 because of indexing hash by raw DB data
			}
			when ('tag') {
				$dbh->do(
					'INSERT INTO camp_planner_tags(plan_id, tag)
					VALUES (?, ?)',
					undef,
					$self->{_plan_id}, $self->{_add_name}
				) unless defined $self->{_db}->{tags}->{encode('utf8',$self->{_plan_id}.$self->{_add_name})};
				# encode to utf8 because of indexing hash by raw DB data
			}
		}
		commit();
		$self->checkModified();
		redirect(current_cgi().'?mode=detail&plan_id='.$self->{_plan_id});
	}
	if ($self->{_mode} eq 'detail' && $self->{_add} eq 'material' && length $self->{_add_name}) {
		if ($self->{_edit_material} == 0) {
			$dbh->do(
				'INSERT INTO camp_planner_materials(plan_id, name, note, completed)
				VALUES (?, ?, ?, 0)',
				undef,
				$self->{_plan_id}, $self->{_add_name}, $self->{_add_note}
			);
		} else { # edit
			$dbh->do(
				'UPDATE camp_planner_materials
				SET name=?, note=?
				WHERE material_id=?',
				undef,
				$self->{_add_name}, $self->{_add_note},
				$self->{_edit_material}
			);
		}
		commit();
		$self->checkModified();
		redirect(current_cgi().'?mode=detail&plan_id='.$self->{_plan_id}.'#material');
	}
	if ($self->{_mode} eq 'detail' && $self->{_add} eq 'todo' && length $self->{_add_note}) {
		if ($self->{_edit_todo} == 0) {
			$dbh->do(
				'INSERT INTO camp_planner_todos(plan_id, text, completed)
				VALUES (?, ?, 0)',
				undef,
				$self->{_plan_id}, $self->{_add_note}
			);
		} else { # edit
			$dbh->do(
				'UPDATE camp_planner_todos
				SET text=?
				WHERE todo_id=?',
				undef,
				$self->{_add_note},
				$self->{_edit_todo}
			);
		}
		commit();
		$self->checkModified();
		redirect(current_cgi().'?mode=detail&plan_id='.$self->{_plan_id}.'#todo');
	}
	if ($self->{_mode} eq 'detail' && $self->{_remove}) {
		given ($self->{_remove}) {
			when ('org') {
				$dbh->do(
					'DELETE FROM camp_planner_orgs
					WHERE plan_id=? AND type=? AND orgname=?',
					undef,
					$self->{_plan_id}, $self->{_remove_type}, $self->{_remove_name} );
			}
			when ('tag') {
				$dbh->do(
					'DELETE FROM camp_planner_tags
					WHERE plan_id=? AND tag=?',
					undef,
					$self->{_plan_id}, $self->{_remove_name} );
			}
			when ('material') {
				$dbh->do(
					'DELETE FROM camp_planner_materials
					WHERE plan_id=? AND material_id=?',
					undef,
					$self->{_plan_id}, $self->{_remove_id} );
			}
			when ('todo') {
				$dbh->do(
					'DELETE FROM camp_planner_todos
					WHERE plan_id=? AND todo_id=?',
					undef,
					$self->{_plan_id}, $self->{_remove_id} );
			}
		}
		commit();
		$self->checkModified();
		redirect(current_cgi().'?mode=detail&plan_id='.$self->{_plan_id}.'#'.$self->{_remove});
	}
	if ($self->{_mode} eq 'detail' && $self->{_set_completed}) {
		given ($self->{_set_completed}) {
			when ('material') {
				$dbh->do(
					'UPDATE camp_planner_materials
					SET completed=?
					WHERE plan_id=? AND material_id=?',
					undef,
					$self->{_set_completed_value},
					$self->{_plan_id}, $self->{_set_completed_id} );
			}
			when ('todo') {
				$dbh->do(
					'UPDATE camp_planner_todos
					SET completed=?
					WHERE plan_id=? AND todo_id=?',
					undef,
					$self->{_set_completed_value},
					$self->{_plan_id}, $self->{_set_completed_id} );
			}
		}
		commit();
		$self->checkModified();
		redirect(current_cgi().'?mode=detail&plan_id='.$self->{_plan_id}.'#'.$self->{_set_completed});
	}
}

1;
