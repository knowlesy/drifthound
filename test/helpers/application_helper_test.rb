require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "project label defaults to Project" do
    assert_equal "Project", project_label
    assert_equal "Projects", project_label(plural: true)
    assert_equal "project", project_label(lowercase: true)
    assert_equal "projects", project_label(plural: true, lowercase: true)
  end

  test "project_label_count pluralizes with the default label" do
    assert_equal "1 project", project_label_count(1)
    assert_equal "3 projects", project_label_count(3)
    assert_equal "0 projects", project_label_count(0)
  end

  test "project label can be overridden" do
    with_project_label("Layer", "Layers") do
      assert_equal "Layer", project_label
      assert_equal "Layers", project_label(plural: true)
      assert_equal "layer", project_label(lowercase: true)
      assert_equal "layers", project_label(plural: true, lowercase: true)
      assert_equal "1 layer", project_label_count(1)
      assert_equal "3 layers", project_label_count(3)
    end
  end

  test "lower-casing keeps acronyms" do
    with_project_label("AWS Account") do
      assert_equal "AWS account", project_label(lowercase: true)
      assert_equal "AWS accounts", project_label(plural: true, lowercase: true)
    end
  end

  test "label restored after override" do
    with_project_label("Layer") { project_label }
    assert_equal "Project", project_label
  end
end
