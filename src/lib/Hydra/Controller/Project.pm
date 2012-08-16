package Hydra::Controller::Project;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub project : Chained('/') PathPart('project') CaptureArgs(1) {
    my ($self, $c, $projectName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    $c->stash->{project} = $project;
}


sub view : Chained('project') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'project.tt';

    #getBuildStats($c, scalar $c->stash->{project}->builds);

    $c->stash->{views} = [$c->stash->{project}->views->all];
    $c->stash->{jobsets} = [jobsetOverview($c, $c->stash->{project})];
}


sub edit : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'project.tt';
    $c->stash->{edit} = 1;
}


sub submit : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    requirePost($c);
    
    if (($c->request->params->{submit} || "") eq "delete") {
        $c->stash->{project}->delete;
        $c->res->redirect($c->uri_for("/"));
    }

    txn_do($c->model('DB')->schema, sub {
        updateProject($c, $c->stash->{project});
    });
    
    $c->res->redirect($c->uri_for($self->action_for("view"), [$c->stash->{project}->name]));
}


sub hide : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    
    txn_do($c->model('DB')->schema, sub {
        $c->stash->{project}->update({ hidden => 1, enabled => 0 });
    });
    
    $c->res->redirect($c->uri_for("/"));
}


sub unhide : Chained('project') PathPart Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    
    txn_do($c->model('DB')->schema, sub {
        $c->stash->{project}->update({ hidden => 0 });
    });
    
    $c->res->redirect($c->uri_for("/"));
}


sub requireMayCreateProjects {
    my ($c) = @_;
 
    requireLogin($c) if !$c->user_exists;

    error($c, "Only administrators or authorised users can perform this operation.")
        unless $c->check_user_roles('admin') || $c->check_user_roles('create-projects');
}


sub create : Path('/create-project') {
    my ($self, $c) = @_;

    requireMayCreateProjects($c);

    $c->stash->{template} = 'project.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub create_submit : Path('/create-project/submit') {
    my ($self, $c) = @_;

    requireMayCreateProjects($c);

    my $projectName = trim $c->request->params->{name};
    
    error($c, "Invalid project name: ‘$projectName’") if $projectName !~ /^$projectNameRE$/;

    txn_do($c->model('DB')->schema, sub {
        # Note: $projectName is validated in updateProject,
        # which will abort the transaction if the name isn't
        # valid.  Idem for the owner.
        my $owner = $c->check_user_roles('admin')
            ? trim $c->request->params->{owner} : $c->user->username;
        my $project = $c->model('DB::Projects')->create(
            {name => $projectName, displayname => "", owner => $owner});
        updateProject($c, $project);
    });
    
    $c->res->redirect($c->uri_for($self->action_for("view"), [$projectName]));
}


sub create_jobset : Chained('project') PathPart('create-jobset') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    
    $c->stash->{template} = 'jobset.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub create_jobset_submit : Chained('project') PathPart('create-jobset/submit') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    
    my $jobsetName = trim $c->request->params->{name};
    my $exprType = $c->request->params->{exprtype};

    error($c, "Invalid jobset name: ‘$jobsetName’") if $jobsetName !~ /^$jobsetNameRE$/;

    txn_do($c->model('DB')->schema, sub {
        # Note: $jobsetName is validated in updateProject, which will
        # abort the transaction if the name isn't valid.
        my $jobset = $c->stash->{project}->jobsets->create(
            {name => $jobsetName, exprtype => $exprType,
	     nixexprinput => "", nixexprpath => "", emailoverride => ""});
        Hydra::Controller::Jobset::updateJobset($c, $jobset);
    });
    
    $c->res->redirect($c->uri_for($c->controller('Jobset')->action_for("index"),
        [$c->stash->{project}->name, $jobsetName]));
}


sub updateProject {
    my ($c, $project) = @_;
    
    my $owner = $project->owner;
    if ($c->check_user_roles('admin')) {
        $owner = trim $c->request->params->{owner};
        error($c, "Invalid owner: $owner")
            unless defined $c->model('DB::Users')->find({username => $owner});
    }

    my $projectName = trim $c->request->params->{name};
    error($c, "Invalid project name: ‘$projectName’") if $projectName !~ /^$projectNameRE$/;
    
    my $displayName = trim $c->request->params->{displayname};
    error($c, "Invalid display name: $displayName") if $displayName eq "";

    $project->update(
        { name => $projectName
        , displayname => $displayName
        , description => trim($c->request->params->{description})
        , homepage => trim($c->request->params->{homepage})
        , enabled => trim($c->request->params->{enabled}) eq "1" ? 1 : 0
        , owner => $owner
        });
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('project') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->stash->{project}->builds;
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatusForProject')
        ->search({}, {bind => [$c->stash->{project}->name]});
    $c->stash->{allJobsets} = $c->stash->{project}->jobsets;
    $c->stash->{allJobs} = $c->stash->{project}->jobs;
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceededForProject')
        ->search({}, {bind => [$c->stash->{project}->name]});
    $c->stash->{channelBaseName} = $c->stash->{project}->name;
}


sub create_view_submit : Chained('project') PathPart('create-view/submit') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});
    
    my $viewName = $c->request->params->{name};

    my $view;
    txn_do($c->model('DB')->schema, sub {
        # Note: $viewName is validated in updateView, which will abort
        # the transaction if the name isn't valid.
        $view = $c->stash->{project}->views->create({name => $viewName});
        Hydra::Controller::View::updateView($c, $view);
    });

    $c->res->redirect($c->uri_for($c->controller('View')->action_for('view_view'),
        [$c->stash->{project}->name, $view->name]));
}


sub create_view : Chained('project') PathPart('create-view') Args(0) {
    my ($self, $c) = @_;

    requireProjectOwner($c, $c->stash->{project});

    $c->stash->{template} = 'edit-view.tt';
    $c->stash->{create} = 1;
}


sub releases : Chained('project') PathPart('releases') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'releases.tt';
    $c->stash->{releases} = [$c->stash->{project}->releases->search({},
        {order_by => ["timestamp DESC"]})];
}


sub create_release : Chained('project') PathPart('create-release') Args(0) {
    my ($self, $c) = @_;
    requireProjectOwner($c, $c->stash->{project});
    $c->stash->{template} = 'edit-release.tt';
    $c->stash->{create} = 1;
}


sub create_release_submit : Chained('project') PathPart('create-release/submit') Args(0) {
    my ($self, $c) = @_;
    
    requireProjectOwner($c, $c->stash->{project});

    my $releaseName = $c->request->params->{name};

    my $release;
    txn_do($c->model('DB')->schema, sub {
        # Note: $releaseName is validated in updateRelease, which will
        # abort the transaction if the name isn't valid.
        $release = $c->stash->{project}->releases->create(
            { name => $releaseName
            , timestamp => time
            });
        Hydra::Controller::Release::updateRelease($c, $release);
    });

    $c->res->redirect($c->uri_for($c->controller('Release')->action_for('view'),
        [$c->stash->{project}->name, $release->name]));
}


1;
