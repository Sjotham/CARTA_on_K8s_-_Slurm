# after cloning both carta controller and frontend run this file
git submodule update --init --recursive
npm install
npm run build-libs-docker
npm run build-docker
# on both carta frontend and controller dir the run this command to start them
npm run start
