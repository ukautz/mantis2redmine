> This repo is no longer maintained. Get in touch if you want to continue the project yourself.

mantis2redmine
==============


Description
-----------

* Migrate existing Mantis database non-destructive (keeps your Redmine data).
* Able to map Mantis data to coresponding Redmine data (eg users, projects and so on).
* Fully user interactive (suggest what to map to what, but gives you the capability to change.. assume you have a highly configured Mantis installation).
* Things you should keep in mind before migration:
  * Custom fields of the type multi list are not supported in Redmine.
  * Custom fields of the type checkbox with multiple values will be translated to simple lists.
  * Migrates only attachment files which are stored in the database (default).
  * Tested only with Mantis 1.2.19 and Redmine 2.6.6
  * Make a backup of your Redmine database BEFORE you run the script (eg mysqldump..)!


Install
-------

Download the script, put it in some directory. Keep in mind, that it will create several small YAML files and save all attachment files from the Mantis database to disk.

Make it executable:

    chmod +x mantis2redmine.pl

You need perl up and running. Also install prerequisite perl modules (YAML, DBIx::Simple). On debian that would be:

    apt-get install libyaml-perl libdbix-simple-perl

Maybe create a configuration file. All command line parameters could be written in the file.

Example:

    mantis_db_host = localhost
    mantis_db_name = mantis
    mantis_db_login = mantis_user
    mantis_db_pass = mantis_password

    redmine_db_host = localhost
    redmine_db_name = redmine
    redmine_db_login = redmine_user
    redmine_db_pass = redmine_password

You can run the script with '--help' to see all possible parameters.


Usage
-----

I suggest you run the script in dry-run-mode and setup the Mantis->Redmine mappings as you like (script will guide you through):

    ./mantis2redmine.pl -c config.file --dry_run

Even in dry-run-mode all your mappings will be stored in files in the current folder (`store-<name>.map`). If you want re-configure any mapping, simply remove the store-file and run the script again. Now make a backup of your Redmine database and run the script again:

    ./mantis2redmine.pl -c config.file --load_maps

This could take some time, depending on the size of your original Mantis database.

After the script finishes successfully check your Redmine installation. Probably you have to assign the imported (or existing) users to the projects (because Redmine supports groups the script doesn’t do that).

The last step is to copy all exported attachment files (default in `./attachments/` folder) in your Redmine file directory (in a "normal" Redmine installation this would be `/files` in your Redmine base dir; if you installed via debian apt-get it is in `/var/lib/redmine/default/files`).

Done.

Known Issues
------------

Versions are not correctly assigned to projects if a version with the same name already exists in another project. E.g.If projects 'A' and 'B' both have a version named '1.0.0' project 'B' gets the '1.0.0' of project 'A' assigned (or vice versa - the order is not deterministic!).

