require_relative "../test_helper"

class Test::AdminUi::TestApiUsersAllowedIps < Minitest::Capybara::Test
  include Capybara::Screenshot::MiniTestPlugin
  include ApiUmbrellaTestHelpers::AdminAuth
  include ApiUmbrellaTestHelpers::Setup

  def setup
    super
    setup_server
  end

  def test_empty_input_saves_as_null
    admin_login
    visit "/admin/#/api_users/new"

    fill_in "E-mail", :with => "example@example.com"
    fill_in "First Name", :with => "John"
    fill_in "Last Name", :with => "Doe"
    check "User agrees to the terms and conditions"
    click_button("Save")

    assert_text("Successfully saved the user")
    user = ApiUser.order_by(:created_at.asc).last
    assert_nil(user["settings"]["allowed_ips"])
  end

  def test_multiple_lines_saves_as_array
    admin_login
    visit "/admin/#/api_users/new"

    fill_in "E-mail", :with => "example@example.com"
    fill_in "First Name", :with => "John"
    fill_in "Last Name", :with => "Doe"
    check "User agrees to the terms and conditions"
    fill_in "Restrict Access to IPs", :with => "10.0.0.0/8\n\n\n\n127.0.0.1"
    click_button("Save")

    assert_text("Successfully saved the user")
    user = ApiUser.order_by(:created_at.asc).last
    assert_equal(["10.0.0.0/8", "127.0.0.1"], user["settings"]["allowed_ips"])
  end

  def test_displays_existing_array_as_multiple_lines
    user = FactoryGirl.create(:api_user, :settings => { :allowed_ips => ["10.0.0.0/24", "10.2.2.2"] })
    admin_login
    visit "/admin/#/api_users/#{user.id}/edit"

    assert_equal("10.0.0.0/24\n10.2.2.2", find_field("Restrict Access to IPs").value)
  end

  def test_nullifies_existing_array_when_empty_input_saved
    user = FactoryGirl.create(:api_user, :settings => { :allowed_ips => ["10.0.0.0/24", "10.2.2.2"] })
    admin_login
    visit "/admin/#/api_users/#{user.id}/edit"

    assert_equal("10.0.0.0/24\n10.2.2.2", find_field("Restrict Access to IPs").value)
    fill_in "Restrict Access to IPs", :with => ""
    click_button("Save")

    assert_text("Successfully saved the user")
    user.reload
    assert_nil(user["settings"]["allowed_ips"])
  end
end
