# Highly Available Auto Scaling Web Application on AWS

A web application that runs on EC2 instances spread across multiple Availability Zones, sits behind an Application Load Balancer, and automatically scales out and in based on CPU load. Built by hand in the AWS Management Console.

## What this project demonstrates

- Designing a custom network (VPC, subnets, routing, internet gateway)
- Restricting access with layered security groups
- Building identical servers from a launch template and a user data script
- Distributing traffic and checking server health with an Application Load Balancer
- Automatic scaling, self-healing, and alerting with Auto Scaling, CloudWatch, and SNS

## Architecture

```
                         Internet
                            |
                   [ Internet Gateway ]
                            |
              +-------------+-------------+
              |   Application Load        |
              |   Balancer (HTTP :80)     |
              +------+------+------+------+
                     |      |      |
              Target group: my-project
                     |      |      |
        +------------+  +---+----+  +------------+
        | Public     |  | Public |  | Public     |
        | Subnet 1   |  | Subnet2|  | Subnet 3   |
        | AZ a       |  | AZ b   |  | AZ c       |
        | EC2        |  | EC2    |  | EC2 ...    |
        +------------+  +--------+  +------------+
              \             |             /
               Auto Scaling group: my-asg
               (min 2, desired 2, max 5)
```

## Resources

| Resource | Name | Key settings |
|---|---|---|
| VPC | `my-vpc-01` | `10.10.0.0/16` |
| Subnets | `Public-Subnet-1/2/3` | `10.10.1.0/24`, `10.10.2.0/24`, `10.10.3.0/24`, one per AZ |
| Internet gateway | `my-internet-gateway` | Attached to `my-vpc-01` |
| Route table | `my-route-table` | `0.0.0.0/0` to the internet gateway, associated with all three subnets |
| Security group | `my-load-balancer-security-group` | Inbound HTTP 80 from `0.0.0.0/0` |
| Security group | `my-web-server-security-group` | Inbound HTTP 80 only from the load balancer security group |
| Launch template | `my-launch-template` | Ubuntu 22.04 LTS, `t2.micro`, user data script |
| Target group | `my-project` | HTTP 80, health check path `/` |
| Load balancer | `my-load-balancer` | Internet-facing ALB across three subnets |
| Auto Scaling group | `my-asg` | Min 2, desired 2, max 5, target tracking at 70% average CPU |
| SNS topic | `my-sns-topic` | Email alerts for launch, terminate, failed launch, failed terminate |

Region: `ap-southeast-2` (Asia Pacific, Sydney). Use the same region for every resource.

## Build steps

### Step 1: VPC, subnets, internet gateway, and route table

1. **VPC** > Your VPCs > Create VPC. Name `my-vpc-01`, IPv4 CIDR `10.10.0.0/16`. Enable DNS hostnames.
2. **Subnets**: create `Public-Subnet-1`, `Public-Subnet-2`, and `Public-Subnet-3` in three different AZs with the CIDRs above. Enable auto-assign public IPv4 on each.
3. **Internet gateway**: create `my-internet-gateway` and attach it to `my-vpc-01`.
4. **Route table**: create `my-route-table` in `my-vpc-01`, associate all three subnets, and add the route `0.0.0.0/0` pointing to the internet gateway.

Why: a subnet is public only when its route table has a route to an internet gateway. Spreading subnets across AZs gives high availability, and an ALB needs at least two.

### Step 2: Security groups

1. `my-load-balancer-security-group`: inbound HTTP (TCP 80) from `0.0.0.0/0`.
2. `my-web-server-security-group`: inbound HTTP (TCP 80) with the **source set to the load balancer security group**, not an IP range.

Why: users can reach only the load balancer, and only the load balancer can reach the servers. Referencing a security group as the source keeps working as instances and ALB addresses change.

### Step 3: Launch template

Create `my-launch-template` with:

- AMI: Ubuntu Server 22.04 LTS (HVM), SSD
- Instance type: `t3.micro`
- Key pair: optional, only needed for SSH
- Security group: `my-web-server-security-group` (no subnet in the template, so the Auto Scaling group can spread instances)
- IAM instance profile: `EC2WebAppProfile` (optional; `CloudWatchAgentServerPolicy` and `AmazonSSMManagedInstanceCore`)
- Hostname type: IP name
- User data: the contents of [`user-data.sh`](user-data.sh)

Why: a launch template is the saved recipe the Auto Scaling group uses to create identical instances without anyone filling in a form.

### Step 4: Target group and Application Load Balancer

1. **Target group** `my-project`: target type Instances, HTTP 80, VPC `my-vpc-01`, health check path `/`. Register no targets by hand.
2. **Load balancer** `my-load-balancer`: internet-facing, IPv4, VPC `my-vpc-01`, all three subnets, security group `my-load-balancer-security-group`, listener HTTP 80 forwarding to `my-project`.

Why: the ALB is the public entry point. The target group lists the servers and checks their health, and the ALB sends traffic only to healthy ones. A 503 at this stage is expected, because no instances are registered yet.

### Step 5: Auto Scaling group

Create `my-asg`:

- Launch template: `my-launch-template`
- VPC and subnets: `my-vpc-01`, all three public subnets
- Load balancing: attach to the existing target group `my-project`
- Health checks: turn on Elastic Load Balancing health checks, grace period 300 seconds
- Group metrics collection in CloudWatch: enabled
- Capacity: desired 2, minimum 2, maximum 5
- Scaling policy: target tracking, average CPU utilization 70%, warmup 300 seconds
- Notifications: SNS topic `my-sns-topic` for launch, terminate, failed to launch, failed to terminate (confirm the subscription email)

Why: the group keeps at least two servers running across AZs, replaces unhealthy ones, and adds or removes servers to hold average CPU near 70%. ELB health checks catch a crashed web server, which plain EC2 checks would miss.

### Step 6: Test

Open the load balancer DNS name in a browser, using `http://` (found under EC2 > Load Balancers > `my-load-balancer` > DNS name).

## Testing

1. **Load balancing**: refresh the page, or run the loop below. The instance ID and Availability Zone should change.

   ```bash
   for i in $(seq 1 10); do
     curl -s http://<ALB-DNS-NAME> | grep "Instance ID"
   done
   ```

2. **Self-healing**: terminate one instance in the EC2 console. The site stays up and the Auto Scaling group launches a replacement.
3. **Scale out**: run a CPU stress test on **both** instances (average CPU must exceed 70%). The group grows toward five instances.

   ```bash
   sudo apt-get install -y stress-ng
   sudo stress-ng --cpu 0 --timeout 900s
   ```

4. **Scale in**: after the load stops, the group shrinks back to two instances, usually after about 15 minutes.

Expect delays: with basic monitoring CloudWatch reports CPU every five minutes, so scale-out can take 5 to 15 minutes.

## Cleanup

The load balancer and instances cost money while they exist. Delete in this order:

1. Auto Scaling group `my-asg`
2. Load balancer `my-load-balancer`
3. Target group `my-project`
4. Launch template `my-launch-template`
5. SNS topic `my-sns-topic`
6. Security groups: `my-web-server-security-group` first, then `my-load-balancer-security-group`
7. Route table `my-route-table` (remove subnet associations first)
8. The three subnets
9. Internet gateway (detach, then delete)
10. VPC `my-vpc-01`

## Possible improvements

- Move instances to private subnets behind a NAT gateway so only the load balancer is public
- Add HTTPS with an ACM certificate and an HTTP to HTTPS redirect
- Recreate the whole setup with Terraform or CloudFormation
- Add a CloudWatch dashboard for request count and target response time
- Switch to a Launch Template version policy and instance refresh for rolling updates

## Security notes

- No private keys, access keys, or account IDs are committed to this repository.
- Instances accept traffic only from the load balancer security group.
- Instances use IMDSv2 (token-based metadata) in the user data script.




