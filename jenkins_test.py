#!/usr/bin/python
# Provision OpenShift disconnected Cluster

# For this script to work, set the following environment variables
# export CLUSTER_TYPE_TEMPLATE='private-templates/functionality-testing/aos-4_6/upi-on-aws/versioned-installer-disconnected'
# export OCP_RELEASE='registry.svc.ci.openshift.org/ocp/release:4.6.6'
# export JENKINS_USER='<<username>>'
# export JENKINS_USER_TOKEN='<<This(API Token) can be generated from jenkins portal configuration>>'

# A sample test execution command for triggering a jenkins job
# to provision disconnected cluster with the version set
# using the above environment variables
# ./jenkins_test_current.py trigger

# A sample test execution command for cleaning up the jenkins job using
# using build number which is set in Environment variable
# ./jenkins_test_current.py cleanup -b 124896


from __future__ import print_function
from jenkinsapi.jenkins import Jenkins
from jenkinsapi.artifact import Artifact
import os
import urllib3
from random import randint
import argparse
import json

urllib3.disable_warnings()

cluster_type_template = os.getenv('CLUSTER_TYPE_TEMPLATE')
ocp_release = "installer_payload_image: "+str(os.getenv('OCP_RELEASE'))
jenkins_user = os.environ['JENKINS_USER']
jenkins_pass = os.environ['JENKINS_USER_TOKEN']
jenkins_url = \
    "https://mastern-jenkins-csb-openshift-qe.cloud.paas.psi.redhat.com"
job_name = "Launch Environment Flexy"
# job_token = "118a583be998ad39d8588e0633eddf6a1f"
kubeconfig_artifact = 'kubeconfig'
kubeadmin_password_artifact = 'kubeadmin-password'
mirror_registry_artifact = 'cluster_info.json'
artifacts_url = "{}/job/{}/{}/artifact//workdir/install-dir/auth/{}"
remove_job_name = "Remove VMs"
templates_repo = 'https://gitlab.cee.redhat.com/aosqe/flexy-templates.git'

jenkins = Jenkins(
    jenkins_url,
    username=jenkins_user,
    password=jenkins_pass,
    ssl_verify=False,
    timeout=60
)


def trigger_openshift_cluster_provision(cause=None):
    INSTANCE_NAME = jenkins_user+str(randint(1, 500))
    print('Using Cluster type template - {} \nOCP Release - {} \n'.format(cluster_type_template, ocp_release))
    params = {'VARIABLES_LOCATION': cluster_type_template,
              'LAUNCHER_VARS': ocp_release, 'INSTANCE_NAME_PREFIX': INSTANCE_NAME}

    # This will start the job and will return a QueueItem object which
    # can be used to get build results
    job = jenkins[job_name]
    qi = job.invoke(
        # securitytoken=job_token,
        build_params=params,
        # cause=cause
    )

    if qi.is_queued():
        qi.block_until_building()

    build = qi.get_build()

    if build.is_running():
        build.block_until_complete(delay=40)

    build_number = build.get_number()

    build = job.get_build(build_number)
    print("Build {} finished with {}.".format(build, build.get_status()))

    get_artifacts(
        build_number, build, artifact=kubeconfig_artifact,
        url=artifacts_url)

    get_artifacts(build_number, build,
                  artifact=kubeadmin_password_artifact,
                  url=artifacts_url)

    artifact_obj = get_artifacts(build_number, build,
                                 artifact=mirror_registry_artifact,
                                 url="{}/job/{}/{}/artifact//workdir/install-dir/{}")

    artifact_data = artifact_obj.get_data()
    json_data = json.loads(artifact_data)
    return build_number, json_data['MIRROR_REGISTRY']


def delete_cluster(build_number):
    params = {'BUILD_NUMBER': build_number,
              'TEMPLATES_REPO': templates_repo, 'TEMPLATES_BRANCH': 'master'}
    job = jenkins[remove_job_name]
    qi = job.invoke(
        build_params=params)
    if qi.is_queued() or qi.is_running():
        qi.block_until_complete()


def get_artifacts(build_number, build, dir='.',
                  artifact=None, url=None):
    artifact_obj = Artifact(artifact, url.
                            format(jenkins_url, job_name,
                                   build_number, artifact), build)
    print("Downloading {} to {}".format(artifact, dir+artifact))
    artifact_obj.save("./"+artifact)
    return artifact_obj


parser = argparse.ArgumentParser(
    description="Provision OpenShift Disconnected Cluster")

trigger_parser = argparse.ArgumentParser(add_help=False)
trigger_parser.add_argument("-m", "--cause-message", dest="cause",
                            default=os.getenv("BUILD_URL"), type=str,
                            help="Trigger job cause")

delete_parser = argparse.ArgumentParser(add_help=False)
delete_parser.add_argument("-b", "--build-number", dest="build_number", type=int,
                           help="Jenkins job build number", required=True)

sp = parser.add_subparsers(dest="action")
sp.add_parser("trigger", parents=[
    trigger_parser], help="Trigger provisioning of a new OpenShift Disconnected Cluster of a given version, return a # of a Jenkins Build")
sp.add_parser("cleanup", parents=[
    delete_parser], help="Wait for a given Jenkins Build to do the cleanup")

args = parser.parse_args()

if args.action == "trigger":
    build_number, mirror_registry = trigger_openshift_cluster_provision()
    print('export build_number="{}"'.format(build_number))
    print('export mirror_registry="{}"'.format(mirror_registry))
elif args.action == "cleanup":
    delete_cluster(args.build_number)
else:
    parser.print_help()
