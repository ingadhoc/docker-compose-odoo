#!/usr/bin/python
# -*- coding: utf-8 -*-
import os
import pprint
import subprocess


class GenerateCustom(object):

    def __init__(self):
        self.default_path = os.path.join(os.getcwd(), 'data/default/repositories')
        self.custom_dirname = os.path.basename(os.getcwd()) # ${PWD##}
        self.branch = self.custom_dirname + '.0'
        self.org = 'ingadhoc'
        self.custom_path = os.path.join(os.getcwd(), 'data/custom/dev')
        self.confirm_run(self.__dict__)

    def confirm_run(self, args):
        """
        Manual confirmation before runing the script. Very usefull.
        @param args: dictionary of arguments.
        @return True or exit the program in the confirm is no.
        """
        pprint.pprint('\n... Configuration of Parameters Set')
        for (parameter, value) in args.iteritems():
            pprint.pprint('%s = %s' % (parameter, value))

        question = 'Confirm the run with the above parameters?'
        answer = 'The script parameters were confirmed by the user'
        confirm_flag = False
        while confirm_flag not in ['y', 'n']:
            confirm_flag = raw_input(question + ' [y/n]: ')
            if confirm_flag == 'y':
                pprint.pprint(answer)
            elif confirm_flag == 'n':
                pprint.pprint('The user cancel the operation')
                exit()
            else:
                pprint.pprint('The entry is not valid, please enter y or n.')
        return True

    def run(self):
        self.copy_repos()
        self.set_remotes()
        self.unshallow()
        self.remove_single_branch()

    def copy_repos(self):
        os.system('echo "" && echo "STEP 1/4: Copy all the %s repos to data/custom ..."' % self.org)

        os.system('echo "" && echo "Create custom path %s"' % self.custom_path)
        if os.path.exists(self.custom_path):
            os.system('echo "Dont do anything, Already exists"')
        else:
            os.system('mkdir %s' % (self.custom_path))

        for repository in os.listdir(self.default_path):
            if self.org in repository:
                custom_repository = os.path.join(self.custom_path, repository)
                os.system('echo "" && echo "Copy repository %s"' % repository)
                if os.path.exists(custom_repository):
                    os.system('echo "Dont do anything, Already exists"')
                else:
                    os.system('cp -r %s %s' % (
                        os.path.join(self.default_path, repository),
                        custom_repository))
                    os.system('ls -la %s' % (custom_repository))
                    os.system('echo "Ready!"')

    def set_remotes(self):
        os.system('echo "" && echo "STEP 2/4: Set SSH Remotes for ingadhoc/adhoc-dev"')

        for directory in os.listdir(self.custom_path):
            organization, repository = directory.split('-', 1)
            os.system('echo "" && echo "Process repository %s"' % directory)

            repo_url = subprocess.check_output(
                'cd %s && git remote get-url origin' % (os.path.join(
                    self.custom_path, directory)), shell=True)

            plataform = 'github.com' if 'github' in repo_url else (
                'bitbucket.org' if 'bitbucket' in repo_url else 'gitlab.com')
            dev_org = 'ingadhoc' if plataform == 'bitbucket' else 'adhoc-dev'

            os.system('cd {path} && git remote set-url origin git@{plataform}:{organization}/{repository}.git'.format(
                path=os.path.join(self.custom_path, directory),
                organization=organization,
                repository=repository,
                plataform=plataform,
            ))
            os.system('cd {path} && git remote add adhoc-dev git@{plataform}:{dev_org}/{repository}.git'.format(
                path=os.path.join(self.custom_path, directory),
                repository=repository,
                plataform=plataform,
                dev_org=dev_org,
            ))
            os.system('cd %s && git remote -v' % os.path.join(
                self.custom_path, directory))
            os.system('echo "Ready!"')

    def unshallow(self):
        os.system('echo "" && echo "STEP 3/4: Unshallow repositories"')
        for directory in os.listdir(self.custom_path):
            os.system('echo "" && echo "Unshallow repository %s"' % directory)
            os.system('cd %s && git fetch --unshallow' % os.path.join(self.custom_path, directory))
            os.system('echo "" && echo "Pull last changes"')
            os.system('cd {path} && git pull origin {branch}'.format(
                path=os.path.join(self.custom_path, directory),
                branch=self.branch,
            ))
            os.system('cd %s && git status' % os.path.join(self.custom_path, directory))
            os.system('echo "Ready!"')

    def remove_single_branch(self):
        os.system('echo "" && echo "STEP 4/4: Remove single branch"')
        for directory in os.listdir(self.custom_path):
            os.system('echo "" && echo "Remove single branch for repository %s"' % directory)
            os.system('cd %s && git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"' % os.path.join(
                self.custom_path, directory))
            os.system('cd %s && git fetch origin' % os.path.join(self.custom_path, directory))
            os.system('echo "Ready!"')


def main():
    obj = GenerateCustom()
    obj.run()
    return True

if __name__ == '__main__':
    main()
