#!/usr/bin/python
# -*- coding: utf-8 -*-
import os
import pprint
import argparse


class UpdateCustomRepos(object):

    epilog = '\n'.join([
        'Odoo Developer Comunity Tool',
        'Developed by Katherine Zaoral github:@zaoral',
        ' '
    ])

    description = '\n'.join([
        'Make pull of all the repositories inside custom/repositories. Run:\n',
        '\tgit add .',
        '\tgit stash',
        '\tgit checkout main-branch',
        '\tgit fetch origin main-branch',
        '\tgit status',
        '\tgit pull origin main-branch',
        '\tgit checkout -',
        '\tgit stash pop'])

    def __init__(self):
        self.args = self.argument_parser()
        self.checkout_dev = self.args['checkout_dev']

        self.custom_dirname = os.path.basename(os.getcwd())  # ${PWD##}
        self.branch = self.custom_dirname + '.0'
        self.custom_path = os.path.join(os.getcwd(), 'data/custom/repositories')
        self.confirm_run(self.__dict__)

    def argument_parser(self):
        """ This function create the help command line, manage and filter the
        parameters of this script (default values, choices values).
        @return dictionary of the arguments.
        """
        parser = argparse.ArgumentParser(
            prog='update_custom_repo',
            formatter_class=argparse.RawTextHelpFormatter,
            description=self.description,
            epilog=self.epilog)

        parser.add_argument(
            '--checkout-dev',
            action='store_true',
            help=('In repo in branch different from main will checkout to the branch before pull'))
        return parser.parse_args().__dict__

    def confirm_run(self, args):
        pprint.pprint('... Configuration of Parameters Set')
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
        self.update_custom_repos()

    def update_custom_repos(self):
        os.system('echo "" && echo "Update Custom Repositories"')
        for directory in os.listdir(self.custom_path):
            path = os.path.join(self.custom_path, directory)
            os.system('echo "" && echo "**** Process repository %s"' % directory)
            os.system('cd %s && git add .' % (path))
            os.system('cd %s && git stash' % (path))
            os.system('cd %s && git checkout %s' % (path, self.branch))
            os.system('cd %s && git fetch origin %s' % (path, self.branch))
            os.system('cd %s && git status' % (path))
            os.system('cd %s && git pull origin %s' % (path, self.branch))
            if self.checkout_dev:
                os.system('cd %s && git checkout -' % (path))
                os.system('cd %s && git stash pop' % (path))
            os.system('echo "Ready!"')


def main():
    obj = UpdateCustomRepos()
    obj.run()
    return True

if __name__ == '__main__':
    main()
