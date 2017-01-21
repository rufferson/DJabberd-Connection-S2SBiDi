#!/usr/bin/perl
use 5.008;
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME => 'DJabberd::Connection::ServerBiDi',
	VERSION_FROM => 'lib/DJabberd/Connection/ServerBiDi.pm',
	ABSTRACT_FROM => 'lib/DJabberd/Connection/ServerBiDi.pm',
	PREREQ_PM => {
		'DJabberd' => '0.86',
	},
	AUTHOR => 'Ruslan N. Marchenko <me@ruff.mobi>',
);
