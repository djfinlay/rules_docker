# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Test rule for verifying a given container_image target produces a
   deterministic Docker image.

This rule builds the given container_image twice in isolation to determine if
the given image is deterministic.
It does so by mounting the provided Bazel project files into the 'base' image.
Next it starts two containers and builds the supplied container_image target
(being 'image') inside each of the containers. The rule then extracts the
output files for the test image. Finally, both extracted images are compared.
A test image is considered to be reproducible when both instances of the same
image have the same digest and ID. On a mismatch of one of those values, the
test fails and the container_diff tool
(https://github.com/GoogleContainerTools/container-diff#container-diff)
produces the summary of their differences.

Args:
    image: A container_image target to test for determinism.
    workspace_file: The WORKSPACE file of the project containing the 'image'
                    target to help detect project's root path.
    base: (optional) An image target to build and reproduce the 'image 'in.
          This image must have Bazel and docker installed and available in the PATH.
    container_diff_args: (optional) Args to the container_diff tool as specified here:
                         https://github.com/GoogleContainerTools/container-diff#quickstart

NOTE:

Since every container_repro_test target requires specifying the WORKSPACE file
(in the 'workspace_file' attribute) of the current project (as shown in the
examples below), it is required to have a top level BUILD file exporting the
WORKSPACE file like so:

exports_files(["WORKSPACE"])

Examples:

container_repro_test(
    name = "set_cmd_repro_test",
    image = "//tests/container:set_cmd",
    workspace_file = "//:WORKSPACE",
)

container_repro_test(
    name = "derivative_with_volume_repro_test",
    base = "@bazel_0271//image",
    container_diff_args = [
        "history",
        "file",
        "size",
        "rpm",
        "apt",
        "pip",
        "node",
    ],
    image = "//testdata:derivative_with_volume",
    workspace_file = "//:WORKSPACE",
)
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("//container:container.bzl", _container = "container")
load("//docker/util:run.bzl", _extract = "extract")

def _impl(ctx):
    """Core implementation of container_repro_test"""

    name = ctx.attr.name
    workspace_file = ctx.file.workspace_file
    proj_root = ctx.actions.declare_file(name + "_src_project_root.txt")

    # Record the absolute path to the provided WORKSPACE file and assume it to
    # be the root of the Bazel project to build the 'image' in.
    ctx.actions.run_shell(
        command = "readlink -f %s | xargs dirname >> %s" % (workspace_file.path, proj_root.path),
        inputs = [workspace_file],
        outputs = [proj_root],
    )

    # Tar the current source project files to mount into the image that will
    # be used to build and repro the 'image' in.
    proj_tar = ctx.actions.declare_file(name + "_src_project.tar")
    ctx.actions.run_shell(
        command = "tar -cvf %s \"$(cat %s)\"" % (proj_tar.path, proj_root.path),
        inputs = [proj_root],
        outputs = [proj_tar],
    )

    # TODO(alex1545): It's a good idea to remove this big file after the test
    # is executed, especially that it's only needed as an intermediate step.
    # Try to find out if there is a way to remove a declared file.
    # Simply running ctx.actions.run_shell with the 'rm' commond doesn't work.
    image_tar = ctx.actions.declare_file(name + ".tar")

    # Build the base image to build and repro the 'image' in.
    # Mount the source project and its path into this image.
    _container.image.implementation(
        ctx,
        files = [proj_root],
        tars = [proj_tar],
        output_executable = ctx.actions.declare_file(name + "_load.sh"),
        output_tarball = image_tar,
        workdir = "/",
    )

    img_label = ctx.attr.image.label
    img_name = img_label.name
    img_pkg = img_label.package
    img_target_str = "//" + img_pkg + ":" + img_name

    build_targets = [
        img_target_str,
        img_target_str + ".tar",
        img_target_str + ".digest",
        img_target_str + ".json",
    ]
    extract_path = "/img_outs"
    img_tar = img_name + ".tar"
    img_digest = img_name + ".digest"

    # Commands to build the image targets and copy the files required for image
    # comparison to a known location in the container (being 'extract_path').
    commands = [
        "cd \$(cat /%s)" % proj_root.basename,
        "bazel build " + " ".join(build_targets),
        "mkdir %s" % extract_path,
        "cp bazel-bin/%s/%s %s/%s" % (img_pkg, img_tar, extract_path, img_tar),
        "cp bazel-bin/%s/%s %s/%s" % (img_pkg, img_digest, extract_path, img_digest),
        "cp \$(readlink -f bazel-bin/%s/%s).sha256 %s/%s" % (img_pkg, img_name + ".json", extract_path, img_name + ".id"),
    ]

    # Mount the docker.sock inside the running container to enable docker
    # sibling, which is needed when builing the test image itself requires
    # running another container.
    docker_run_flags = [
        "--entrypoint",
        "''",
        "-v",
        "/var/run/docker.sock:/var/run/docker.sock",
    ]

    img1_outs = ctx.actions.declare_directory(name + "_test_img1_outs")
    img2_outs = ctx.actions.declare_directory(name + "_test_img2_outs")

    # Build and extract 'image' inside a container.
    _extract.implementation(
        ctx,
        name = "build_image_and_extract",
        commands = commands,
        extract_file = extract_path,
        image = image_tar,
        docker_run_flags = docker_run_flags,
        output_file = img1_outs,
        script_file = ctx.actions.declare_file(name + ".build1"),
    )

    # Build and extract 'image' again in a different container to try and
    # repro previously built 'image'.
    _extract.implementation(
        ctx,
        name = "build_image_and_extract_repro",
        commands = commands,
        extract_file = extract_path,
        image = image_tar,
        docker_run_flags = docker_run_flags,
        output_file = img2_outs,
        script_file = ctx.actions.declare_file(name + ".build2"),
    )

    # Expand template to run the image comparison test.
    type_args = ["--type=" + type_arg for type_arg in ctx.attr.container_diff_args]
    diff_tool_exec = ctx.executable._container_diff_tool
    ctx.actions.expand_template(
        template = ctx.file._test_tpl,
        substitutions = {
            "%{container_diff_args}": " ".join(type_args),
            "%{container_diff_tool}": diff_tool_exec.short_path,
            "%{img1_path}": img1_outs.short_path + extract_path,
            "%{img2_path}": img2_outs.short_path + extract_path,
            "%{img_name}": img_label.name,
        },
        output = ctx.outputs.test_script,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = [img1_outs, img2_outs, diff_tool_exec])

    return [
        DefaultInfo(
            executable = ctx.outputs.test_script,
            runfiles = runfiles,
        ),
    ]

container_repro_test = rule(
    attrs = dicts.add(_container.image.attrs, {
        "base": attr.label(
            default = "@bazel_latest//image",
            allow_rules = [
                "container_image_",
                "container_import",
                "toolchain_container_",
            ],
            doc = "An image target compatible with the `base` attribute of " +
                  "the container_image rule to build and reproduce the " +
                  "'image' in. This image must have Bazel and docker " +
                  "installed and available in the PATH.",
        ),
        "container_diff_args": attr.string_list(
            default = ["file", "size", "apt", "pip"],
            doc = "List of the --type flag values to pass to the container_diff tool. " +
                  "Check https://github.com/GoogleContainerTools/container-diff#container-diff " +
                  "for more info.",
        ),
        "image": attr.label(
            allow_rules = [
                "container_image_",
                "toolchain_container_",
            ],
            mandatory = True,
            doc = "A container_image target to test for reproducibility.",
        ),
        "workspace_file": attr.label(
            allow_single_file = ["WORKSPACE"],
            mandatory = True,
            doc = "The WORKSPACE file of the project containing the 'image' " +
                  "target to help detect project's root path.",
        ),
        "_container_diff_tool": attr.label(
            default = Label("@container_diff//file"),
            allow_single_file = True,
            cfg = "target",
            executable = True,
        ),
        "_extract_tpl": attr.label(
            default = Label("//docker/util:extract.sh.tpl"),
            allow_single_file = True,
        ),
        "_image_id_extractor": attr.label(
            default = "//contrib:extract_image_id.py",
            allow_single_file = True,
        ),
        "_test_tpl": attr.label(
            default = Label("//contrib:cmp_images.sh.tpl"),
            allow_single_file = True,
        ),
    }),
    implementation = _impl,
    outputs = dicts.add(_container.image.outputs, {
        "test_script": "%{name}.test",
    }),
    test = True,
    toolchains = ["@io_bazel_rules_docker//toolchains/docker:toolchain_type"],
)
