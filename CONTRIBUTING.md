# Contribution guide

Welcome! We are glad that you want to contribute to our project! 💖

This project accepts contributions via Github pull requests.

This document outlines the process to help get your contribution accepted.

There are many ways to contribute:

* Suggest [features](https://github.com/bouvet/nord-juice-shop/issues/new?assignees=&labels=%3Abulb%3A+feature+request&template=feature-request.md&title=)
* Suggest [changes](https://github.com/bouvet/nord-juice-shop/issues/new?assignees=&labels=%3Awrench%3A+change&template=change-request.md&title=)
* Report [bugs](https://github.com/bouvet/nord-juice-shop/issues/new?assignees=&labels=%3Abug%3A+bug&template=bug-report.md&title=)

You can start by looking through the [good first issues](https://github.com/bouvet/nord-juice-shop/issues?q=is%3Aopen+is%3Aissue+label%3A%22good+first+issue%22).

## Fork the repository

In general, we follow the ["fork-and-pull" Git workflow](https://github.com/susam/gitpr).

Here's a quick guide:

1. Create your own fork of the repository
2. Clone the project to your machine
3. To keep track of the original repository, add another remote named upstream
```shell
git remote add upstream git@github.com:bouvet/nord-juice-shop.git
```
4. Create a branch locally with a succinct but descriptive name and prefixed with change type.
```shell
git checkout -b feature/my-new-feature
```
5. Make the changes in the created branch.
6. Add the changed files
```shell
git add path/to/filename
```
7. Commit your changes using the [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) formatting for the commit messages.
```shell
git commit -m "conventional commit formatted message"
```
8. Before you send the pull request, be sure to rebase onto the upstream source. This ensures your code is running on the latest available code.
```shell
git fetch upstream
git rebase upstream/main
```
9. Push to your fork.
```shell
git push origin feature/my-new-feature
```
10. Submit a pull request to the original repository (via the Github interface). Please provide us with some explanation of why you made the changes you made. For new features, make sure to explain a standard use case to us.

That's it... thank you for your contribution!

After your pull request is merged, you can safely delete your branch.

## Code review process

The core team (defined in [`CODEOWNERS`](.github/CODEOWNERS)) looks at pull requests on a regular basis. After feedback has been given we expect responses within three weeks. After three weeks we may close the pull request if it isn't showing any activity.
