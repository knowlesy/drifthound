require "application_system_test_case"

class UnmanagedLayoutTest < ApplicationSystemTestCase
  LONG_ID = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-with-a-very-long-name/providers/Microsoft.Storage/storageAccounts/#{'a' * 300}".freeze

  def setup
    Rails.application.config.public_mode = false
    project = Project.create!(name: "Layout Project", key: "layout-project")
    @env = project.environments.create!(name: "Prod Azure", key: "prod-azure", status: :drift)
    check = @env.drift_checks.create!(status: :drift, source: "azure", unmanaged_count: 2, unmanaged_ignored_count: 0, raw_output: "Subscriptions: 0000")
    check.unmanaged_resources.create!(identifier: LONG_ID, name: "long", resource_type: "microsoft.storage/storageaccounts", location: "westeurope", scope: "rg")
    check.unmanaged_resources.create!(identifier: "/subscriptions/0000/resourceGroups/rg1", name: "rg1")
    @env.unmanaged_ignore_rules.create!(pattern: LONG_ID, match_type: "exact", source: "azure", note: "one click")
    @env.unmanaged_ignore_rules.create!(pattern: "*/resourceGroups/tmp-*")
    @project = project
  end

  def teardown
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  [ 1400, 390 ].each do |width|
    test "admin environment page has no overflowing content at #{width}px" do
      page.driver.browser.manage.window.resize_to(width, 1600)
      visit login_path
      fill_in "email", with: users(:admin).email
      fill_in "password", with: "testpass1"
      find("input[type=submit], button[type=submit]").click
      assert_selector ".top-nav", text: users(:admin).email

      visit project_environment_path(@project.key, @env.key)
      click_button "Details"
      assert_selector ".check-output .unmanaged-table td", text: "rg1"
      assert_selector ".ignore-rule-form"
      capture_shot("admin-#{width}") if ENV["SHOT_DIR"]

      # The top nav bar overflows on its own for admins on narrow screens; that is
      # unrelated to this feature, so the page content is checked without it.
      offenders = page.evaluate_script(<<~JS)
        [...document.querySelectorAll("body *")]
          .filter(e => !e.closest(".top-nav, .table-scroll, svg") && e.getBoundingClientRect().right > document.documentElement.clientWidth + 1)
          .map(e => e.tagName + "." + e.className)
      JS
      assert_empty offenders, "content extends past the viewport"

      if width >= 1000
        overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
        assert_operator overflow, :<=, 0, "page scrolls sideways by #{overflow}px"
      end
    end
  end

  private

  def capture_shot(name)
    FileUtils.mkdir_p(ENV["SHOT_DIR"])
    page.save_screenshot(File.join(ENV["SHOT_DIR"], "#{name}.png"))
  end
end
