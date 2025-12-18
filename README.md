# awesome-oci-images

A curated collection of **OCI images** built and maintained by **SLASH MNT** to support modern CI/CD workflows, secure networking, and essential tooling for **Kubernetes engineers**.

This repository groups reusable, secure, and purpose-built container images designed to accelerate development and operational workflows while adhering to best practices for security and interoperability with Kubernetes and cloud-native environments.

---

## Purpose

Containers and OCI images are fundamental building blocks in modern cloud-native and DevOps ecosystems.  
This repository exists to:

- Provide ready-to-use OCI images for common CI/CD and infrastructure tasks
- Offer images that embed secure defaults and tooling suited for Kubernetes workloads
- Enable teams to integrate these images into workflows rapidly
- Reduce duplicated effort in building and maintaining custom images

All images published here are intended to be:

- Compliant with OCI standards
- Secure by design
- Easy to consume in GitHub Actions, GitLab CI/CD, Argo CD, Flux, and other orchestrators
- Compatible with Kubernetes and container registries

> OCI (Open Container Initiative) images are a standard container image format designed for interoperability across registries and runtimes.

---

## Contents

This repository contains (or will contain) multiple OCI images, for example:

- **CI tools images** — preconfigured environments with build tools, linters, and scanners
- **Networking & security images** — tools for secure connections, policy enforcement, and analysis
- **Utility images** — debugging, observability, and maintenance toolkits for clusters

Each image has its own folder containing a:

- `Containerfile` / build definitions
- Documentation explaining purpose, usage, and configuration
- Tags describing versions and how to pull them

> If a specific image is missing documentation, see the corresponding folder or open an issue to request it.

---

## Usage

Each OCI image in this repository can be consumed in standard container workflows.  
You can pull an image directly from your OCI registry (public or hosted) using standard tools:

```bash
# Example for pulling an image
docker pull docker.io/slashmnt/<image-name>:<tag>
```

or reference it in Kubernetes manifests:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example
spec:
  template:
    spec:
      containers:
      - name: example
        image: docker.io/slashmnt/<image-name>:<tag>

```

Replace `<image-name>` and `<tag>` with the specific image and version you need.

## Tags and Releases

Images may be published with the following tag strategies:

* `latest` — the most recent non-breaking build
* `vX.Y.Z` — strict version tags for reproducible workflows

Refer to the image folder or published registry for available tags.

## Contributing

Contributions are welcome and encouraged.

To contribute:

1. Fork this repository
2. Add or update an image directory
3. Include:
  1. A clear `README.md` per image
  2. A build definition (`Containerfile`, build scripts)
  3. Tags for versions
4. Submit a pull request with a description of your changes

Please ensure your images:

* Follow OCI image best practices
* Minimize attack surface and unnecessary packages
* Include clear documentation

## Security

If you discover vulnerabilities or security issues:

1. Create an issue describing the problem
2. Avoid disclosing sensitive details publicly
3. Optionally open a pull request with a fix

Images should adhere to security best practices, and maintainers will address any confirmed issues promptly.

## License

This repository and its contents are licensed under the GPL-3.0 License.
See the `LICENSE` file for full license terms.

## Credits

Maintained by SLASH MNT — providing tools and infrastructure for cloud-native engineering and secure systems.
