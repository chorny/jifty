package TestApp::Model::User;
use warnings;
use strict;
use base qw/TestApp::Record/;
use Jifty::DBI::Schema;
use Scalar::Defer;

# Your column definitions go here.  See L<Jifty::DBI::Schema> for
# documentation about how to write column definitions.
use Jifty::Record schema  {
column 'name' =>
  type is 'text',
  is mandatory;
column 'email' =>
  type is 'text',
  is mandatory;
column 'really_tasty' =>
  type is 'boolean',
  is immutable,
  since '0.0.2';
column 'tasty' =>
  type is 'boolean',
  is immutable,
  till '0.0.2';
column 'password' =>
  type is 'text',
  render_as 'Password',
  is mandatory,
  default is '';
column 'created_on' =>
  type is 'datetime',
  is immutable,
  default is defer { DateTime->now },
  filters are 'Jifty::DBI::Filter::DateTime';
};


# Your model-specific methods go here.
sub current_user_can {
    return 1;
}

1;

