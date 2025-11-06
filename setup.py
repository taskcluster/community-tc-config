from setuptools import setup, find_packages

setup(
    name="community-tc-config",
    version="1.0.0",
    description="Configuration for Taskcluster at https://community-tc.services.mozilla.com/",
    author="Dustin Mitchell",
    author_email="dustin@mozilla.com",
    url="https://github.com/taskcluster/community-tc-config",
    packages=find_packages("."),
    install_requires=[
        "tc-admin>=5.1.1",
        "json-e>=4.7.1",
        "ruamel.yaml",
    ],
    setup_requires=["pytest-runner"],
    tests_require=["pytest-mock", "pytest-asyncio"],
    classifiers=[
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Programming Language :: Python :: 3.14",
    ],
)
