My Cmp>
ssh -i ~/Downloads/login-to-test-1.pem ec2-user@HOST

mkdir -p ~/.terminfo/r/
sudo yum -y install git tmux htop gcc48 cmake openssl-devel

My cmp>
scp -i ~/Downloads/login-to-test-1.pem /usr/share/terminfo/r/rxvt-unicode* ec2-user@HOST:.terminfo/r/

tmux

git clone https://github.com/alex-ozdemir/unsafe-ast.git
cd unsafe-ast
sh ./src/batch/setup.sh
source ~/.profile
sh ./src/batch/do-analysis.sh crate-list.txt 2>&1 | tee output/RAW.out
tar -cvzf output.tar.gz output

My cmp>
scp -i ~/Downloads/login-to-test-1.pem  ec2-user@HOST:./unsafe-ast/output.tar.gz ./output.tar.gz
tar -xvzf output.tar.gz
