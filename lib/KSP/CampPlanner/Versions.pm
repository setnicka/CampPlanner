package KSP::CampPlanner::Versions;
# CampPlanner - plan games and activities during KSP camps (internal version control system)
# (c) 2013-2014 Jiří Setnička <setnicka@seznam.cz>

use common::sense;
use locale;

use KSP;
use KSP::CGI;
use UCW::CGI;

use KSP::DB;
use Date::Parse;
use Text::Diff;
use Text::Wrap;

use Encode;
use POSIX;
use Data::Dumper; # testing

ensureDB(utf8 => 1);

sub new {
	my $class = shift;
	my $self = {
		Main => shift,
		View => shift
	};

	bless $self, $class;
	return $self;
}

sub getLast($) {
	my ($self, $plan_id) = @_;

	my $commit = $dbh->selectrow_hashref('
		SELECT commit
		FROM camp_planner_commits
		WHERE plan_id=?
		ORDER BY commit_id DESC
		LIMIT 1',
	undef, $plan_id);

	return $commit->{commit} if $commit;
	return '';
}

sub getActual() {
	my $self = shift;
	my $plan_id = shift;
	$plan_id = $self->{Main}->{_plan_id} unless $plan_id;
	die "Unknown plan_id!\n" unless $plan_id;

	my $db_materials = $dbh->selectall_hashref("
		SELECT *
		FROM camp_planner_materials
		WHERE plan_id=?",
	'material_id', undef, $plan_id);
	my $db_todos = $dbh->selectall_hashref("
		SELECT *
		FROM camp_planner_todos
		WHERE plan_id=?",
	'todo_id', undef, $plan_id);
	my $db_tags = $dbh->selectall_hashref("
		SELECT *
		FROM camp_planner_tags
		WHERE plan_id=?",
	'tag', undef, $plan_id);

	my $actual = $self->{View}->textSummary($plan_id, $db_materials, $db_todos, $db_tags);

	return $actual;
}

sub commitChanges($$) {
	my ($self, $plans, $commit_message) = @_;

	my($commit_id, $now) = $dbh->selectrow_array(
		'SELECT MAX(commit_id)+1, NOW()
		FROM camp_planner_commits'
	);
	$commit_id = 1 unless $commit_id;
	my $user = $self->{Main}->{_user};

	my $emailText = sprintf "Autor commitu: %s\nShrnutí commitu: %s\n\n\n",
		$user->{name},
		$commit_message;
	my $subject = '';

	for my $plan_id (@{$plans}) {
		my $last = $self->getLast($plan_id);
		my $actual = $self->getActual($plan_id);
		$emailText .= sprintf "====================\nZměny v %s:\n%s\n\n",
			$self->{Main}->{_db}->{plans}->{$plan_id}->{name},
			diff \$last, \$actual;
		$subject .= ', ' unless $subject eq '';
		$subject .= $self->{Main}->{_db}->{plans}->{$plan_id}->{name};

		$dbh->do(
			'INSERT INTO camp_planner_commits(commit_id, plan_id, uid,
				commit, commit_message, time)
			VALUES (?, ?, ?,
				?, ?, ?)',
			undef,
			$commit_id, $plan_id, $user->{id},
			$actual, $commit_message, $now
		);
	}
	# Add first line of commit message
	$subject .= sprintf ": %s", ( split /\n/, $commit_message )[0] if $commit_message;

	$self->sendEmail($subject,$emailText);

	# Unset modified flag
	$dbh->do( sprintf '
		UPDATE camp_planner SET modified=0
		WHERE plan_id IN(%s)',
		join(',', @{$plans})
	) if @{$plans};
	commit();
}

sub sendEmail($$) {
	my ($self, $subject, $text) = @_;

	my $report_to = (KSP::get_web_variant() ne 'testweb')
		? 'ksp-tech@ksp.mff.cuni.cz' # FIXME
		: 'setnicka@seznam.cz'; # Kdokoliv, kdo zrovna hackuje tento skript
	my $email_from = 'ksp-tech@ksp.mff.cuni.cz';

	my $date = localtime;
	$subject = encode('MIME-Header', sprintf '[PLANNER] %s', $subject );
	my $from_name = encode('MIME-Header', $self->{Main}->{_user}->{name} );

	my $emailbody = sprintf <<EOF, $from_name, $text;
From: %s <$email_from>
To: $report_to
Subject: $subject
Content-Type: text/plain; charset=utf-8

%s
EOF

	open M, "|-:encoding(utf-8)", "/usr/sbin/sendmail -f '$email_from' '$report_to'" or die "Nepodařilo se odeslat mail";
	print M $emailbody;
	close M;
}

1;
