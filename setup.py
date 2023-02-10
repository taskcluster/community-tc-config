from setuptools import setup, find_packages

setup(
    name="community-tc-config",
    version="1.0.0",
    description="Configuration for Taskcluster at https://community-tc.services.mozilla.com/",
    author="Dustin Mitchell",
    author_email="dustin@mozilla.com",
    url="https://github.com/mozilla/community-tc-config",
    packages=find_packages("."),
    install_requires=[
        "tc-admin>=3.3.1",
        "json-e>=4.5.0",
    ],
    setup_requires=["pytest-runner"],
    tests_require=["pytest-mock", "pytest-asyncio"],
    classifiers=("Programming Language :: Python :: 3",),
)
