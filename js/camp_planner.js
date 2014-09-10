function timetableMark(e) {
	var name = jQuery(e).attr('name');
	var classname = '';
	if (name.match(/preparation$/g)) classname = 'hasPreparation';
	if (name.match(/primary$/g)) classname = 'hasPrimary';
	if (name.match(/cleanup$/g)) classname = 'hasCleanup';

	if (jQuery(e).is(':checked')) jQuery(e).parent().addClass(classname);
	else jQuery(e).parent().removeClass(classname);
}

function saveTimetableJSON() {
	var timetable_content = REDIPS.drag.saveContent('campPlanner', 'json');
	console.log(timetable_content);
	jQuery("#timetable_content").val(timetable_content);
}

jQuery(document).ready(function () {
	jQuery("table.campPlanner input:checkbox").each( function() { timetableMark(this); }); // One-time operation on startup
	jQuery("table.campPlanner input:checkbox").change( function() { timetableMark(this); }); // Trigers

	REDIPS.drag.init();
});
