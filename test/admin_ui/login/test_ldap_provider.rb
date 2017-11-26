require_relative "../../test_helper"

class Test::AdminUi::Login::TestLdapProvider < Minitest::Capybara::Test
  include Capybara::Screenshot::MiniTestPlugin
  include ApiUmbrellaTestHelpers::Setup
  include ApiUmbrellaTestHelpers::AdminAuth
  include Minitest::Hooks

  def setup
    super
    setup_server

    once_per_class_setup do
      override_config_set({
        :web => {
          :admin => {
            :username_is_email => false,
            :auth_strategies => {
              :enabled => [
                "ldap",
              ],
              :ldap => {
                :options => {
                  :title => "Planet Express",
                  :host => "127.0.0.1",
                  :port => $config["openldap"]["port"],
                  :base => "dc=planetexpress,dc=com",
                  :uid => "uid",
                },
              },
            },
          },
        },
      }, ["--router", "--web"])
    end
  end

  def after_all
    super
    override_config_reset(["--router", "--web"])
  end

  def test_forbids_first_time_admin_creation
    assert_equal(0, Admin.count)
    assert_first_time_admin_creation_forbidden
  end

  def test_ldap_login_fields_on_login_page_when_exclusive_provider
    visit "/admin/login"

    assert_text("Admin Sign In")

    # No local login fields
    refute_field("Email")
    refute_field("Remember me")
    refute_link("Forgot your password?")

    # No external login links
    refute_text("Sign in with")

    # LDAP login fields on initial page when it's the only login option.
    assert_field("Planet Express Username")
    assert_field("Planet Express Password")
    assert_button("Sign in")
  end

  def test_forbids_ldap_user_without_admin_account
    assert_equal(0, Admin.count)
    visit "/admin/login"
    fill_in "Planet Express Username", :with => "hermes"
    fill_in "Planet Express Password", :with => "hermes"
    click_button "Sign in"
    assert_text("The account for 'hermes' is not authorized to access the admin. Please contact us for further assistance.")
  end

  def test_forbids_ldap_user_with_invalid_password
    FactoryGirl.create(:admin, :username => "hermes", :email => nil, :password_hash => nil)
    visit "/admin/login"
    fill_in "Planet Express Username", :with => "hermes"
    fill_in "Planet Express Password", :with => "incorrect"
    click_button "Sign in"
    assert_text('Could not authenticate you from LDAP because "Invalid credentials".')
  end

  def test_allows_valid_ldap_user
    admin = FactoryGirl.create(:admin, :username => "hermes", :email => nil, :password_hash => nil)
    visit "/admin/login"
    fill_in "Planet Express Username", :with => "hermes"
    fill_in "Planet Express Password", :with => "hermes"
    click_button "Sign in"
    assert_logged_in(admin)
  end

  def test_separate_login_page_used_when_non_exclusive_provider
    admin = FactoryGirl.create(:admin, :username => "hermes", :email => nil, :password_hash => nil)
    visit "/admins/auth/ldap"
    assert_text("Sign in with Planet Express")
    fill_in "Planet Express Username", :with => "hermes"
    fill_in "Planet Express Password", :with => "hermes"
    click_button "Sign in"
    assert_logged_in(admin)
  end
end
