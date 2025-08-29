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
        "tc-admin>=5.0.3",
        "json-e>=4.7.1",
    ],
    setup_requires=["pytest-runner"],
    tests_require=["pytest-mock", "pytest-asyncio"],
    classifiers=[
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
    ],
)
